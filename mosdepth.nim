import hts as hts
import tables
import strutils as S
import algorithm as alg
import sequtils as sequtils
import strutils as su
import os
import docopt
import times

proc setvbuf(stream: File, buf: cstring, buftype: int, size: int32): int {.importc: "setvbuf", header:"<stdio.h>".}
type
  pair = tuple[pos: int, value: int32]
  depth_t = tuple[start: uint32, stop: uint32, value: uint32, tid: uint32]
  region_t = ref object
    chrom: string
    start: uint32
    stop: uint32
    name: string

  coverage_t = seq[int32]

proc `$`(r: region_t): string =
  if r == nil:
    return nil
  if r.stop != 0:
    return format("$1:$2-$3", r.chrom, r.start + 1, r.stop)
  else:
    return format("$1:$2", r.chrom, r.start + 1)

proc to_coverage(c: var coverage_t) =
  # to_coverage converts from an array of start/end inc/decs to actual coverage.
  var d = int32(0)
  for i, v in pairs(c):
    d += v
    c[i] = d

proc length(r: region_t): int =
  return int(r.stop - r.start)

iterator gen_depths(arr: coverage_t, offset: uint32, istop: int, tid: uint32): depth_t =
  # given `arr` with values in each index indicating the number of reads
  # starting or ending at that location, generate depths.
  # offset is only used for a region like chr6:200-30000, in which case, offset will be 200
  var
    last_depth = -1
    depth = 0
    i = uint32(0)
    last_i = uint32(0)
    stop: uint32
  if istop <= 0:
    stop = uint32(len(arr)-1)
  else:
    stop = uint32(istop)
  # even with an offset, have to start from the beginning of the array
  # to get the proper depth.
  for depth in arr:
    if i == stop:
      break
    if i < offset or depth == last_depth:
      inc(i)
      continue

    if last_depth != -1:
      yield (last_i, i, uint32(last_depth), tid)

    last_depth = depth
    last_i = i
    if i + 1 == stop: break
    inc(i)

  if last_i < stop:
    yield (last_i, uint32(len(arr)-1), uint32(last_depth), tid)

  # this is horrible, but it works. we don't know
  # if we've already printed the record on not.
  elif  last_i != i:
      yield (last_i - 1, i, uint32(last_depth), tid)
  else:
      yield (last_i, i, uint32(last_depth), tid)

proc pair_sort(a, b: pair): int =
   return a.pos - b.pos

iterator gen_start_ends(c: Cigar, ipos: int): pair =
  # generate start, end pairs given a cigar string and a position offset.
  if c.len == 1 and c[0].op == CigarOp(match):
    yield (ipos, int32(1))
    yield (ipos + c[0].len, int32(-1))
  else:
    var pos = ipos
    var last_stop = -1
    var con: Consume
    for op in c:
      con = op.consumes
      if not con.reference:
        continue
      var olen = op.len
      if con.query:
        if pos != last_stop:
          yield (pos, int32(1))
          if last_stop != -1:
            yield (last_stop, int32(-1))
        last_stop = pos + olen
      pos += olen
    if last_stop != -1:
      yield (last_stop, int32(-1))

proc inc_coverage(c: Cigar, ipos: int = 0, arr: var seq[int32]) {. inline .} =
  for p in gen_start_ends(c, ipos):
      arr[p.pos] += p.value

iterator regions(bam: hts.Bam, region: region_t, tid: int, targets: seq[hts.Target]): Record =
  if region == nil:
    for r in bam:
      yield r
  elif region != nil:
    var stop = region.stop
    if tid != -1:
      if stop == 0:
        stop = targets[tid].length
      for r in bam.queryi(uint32(tid), int(region.start), int(stop)):
        yield r
    else:
      for r in bam.query(region.chrom, int(region.start), int(stop)):
        yield r

proc bed_line_to_region(line: string): region_t =
   var
     cse = sequtils.to_seq(line.strip().split("\t"))

   if len(cse) < 3:
     stderr.write_line("[mosdepth] skipping bad bed line:", line.strip())
     return nil

   var
     s = S.parse_int(cse[1])
     e = S.parse_int(cse[2])
     reg = region_t(chrom: cse[0], start: uint32(s), stop: uint32(e))
   if len(cse) > 3:
     reg.name = cse[3]
   return reg

proc region_line_to_region(region: string): region_t =
  if region == nil or region == "" or region == "nil":
    return nil
  var i = 0
  var r = region_t()
  for w in region.split({':', '-'}):
    if i == 1:
      r.start = uint32(S.parse_int(w)) - 1
    elif i == 2:
      r.stop = uint32(S.parse_int(w))
    else:
      r.chrom = w
    inc(i)
  return r

proc get_tid(tgts: seq[hts.Target], chrom: string): int =
  for t in tgts:
    if t.name == chrom:
      return t.tid

iterator coverage(bam: hts.Bam, arr: var coverage_t, region: var region_t, mapq:int= -1, eflag: uint16=1796): int =
  # depth updates arr in-place and yields the tid for each chrom.
  var
    targets = bam.hdr.targets
    tgt: hts.Target
    mate: Record
    seen = newTable[string, Record]()

  var tid = if region != nil: get_tid(targets, region.chrom) else: -1

  for rec in bam.regions(region, tid, targets):
    if int(rec.qual) < mapq: continue
    if (rec.flag and eflag) != 0:
      continue
    if tgt == nil or tgt.tid != rec.b.core.tid:
        if tgt != nil:
          yield tgt.tid
          flushFile(stdout)
        tgt = targets[rec.b.core.tid]
        if arr == nil or len(arr) != int(tgt.length+1):
          # must create a new array in some cases.
          if arr == nil or len(arr) < int(tgt.length+1):
            arr = new_seq[int32](tgt.length+1)
          else:
            # otherwise can re-use and zero
            arr.set_len(int(tgt.length+1))
            for i in 0..<len(arr):
              arr[i] = 0

        seen.clear()
    # rec:   --------------
    # mate:             ------------
    # handle overlapping mate pairs.
    if rec.flag.proper_pair:
      if rec.b.core.tid == rec.b.core.mtid and rec.stop > rec.matepos and rec.start < rec.matepos:
        var rc = rec.copy()
        seen[rc.qname] = rc
      else:
        if seen.take(rec.qname, mate):
          # we have an overlapping pair, and we know that mate is lower. e.g
          # mate:   --------------
          # rec:             ------------
          # decrement:       -----
          if rec.b.core.n_cigar == 1 and mate.b.core.n_cigar == 1:
            dec(arr[rec.start])
            inc(arr[mate.stop])
          else:
            # track the overlaps of pair.
            # anywhere there is overlap, the cumulative sum of pair.depth will be 2. we dec the start and inc the end of the overlap.
            # this removes the double counting.
            # e.g.:
            # (pos: 4623171, value: 1)(pos: 4623223, value: 1)(pos: 4623240, value: -1)(pos: 4623241, value: 1)(pos: 4623264, value: -1)(pos: 4623320, value: -1)
            # would dec the following intervals:
            # 4623223 4623240
            # 4623241 4623264
            # chr1 4623171 69M1D23M9S (pos: 4623171, value: 1)(pos: 4623241, value: 1)(pos: 4623240, value: -1)(pos: 4623264, value: -1)
            # chr1 4623223 4S97M (pos: 4623223, value: 1)(pos: 4623320, value: -1)
            assert rec.start < mate.stop
            # each element will have a .value of 1 for start and -1 for end.

            var ses = sequtils.to_seq(gen_start_ends(rec.cigar, rec.start))
            for p in gen_start_ends(mate.cigar, mate.start):
                ses.add(p)
            alg.sort(ses, pair_sort)
            var pair_depth = 0
            var last_pos = 0
            #if len(ses) > 4: stderr.write_line ses
            for p in ses:
              assert pair_depth <= 2
              # if we are at pair_depth 2, there is overlap and when the incoming
              # value is -1, then it is dropping back down to 1.
              if p.value == -1 and pair_depth == 2:
                #if len(ses) > 4: stderr.write_line last_pos, " ", p.pos
                dec(arr[last_pos])
                inc(arr[p.pos])
              pair_depth += p.value
              last_pos = p.pos
            assert pair_depth == 0, $rec.qname & ":" & $rec & " " & $mate.qname & ":" & $mate & " " & $pair_depth
    inc_coverage(rec.cigar, rec.start, arr)

  if tgt != nil:
    yield tgt.tid
  flushFile(stdout)

proc bed_gen(bed: string): TableRef[string, seq[region_t]] =
  var bed_regions = newTable[string, seq[region_t]]()
  var hf = hts.hts_open(cstring(bed), "r")
  var kstr: hts.kstring_t
  kstr.l = 0
  kstr.m = 0
  kstr.s = nil
  while hts_getline(hf, cint(10), addr kstr) > 0:
    if ($kstr.s).startswith("track "):
      continue
    var v = bed_line_to_region($kstr.s)
    if v == nil: continue
    discard bed_regions.hasKeyOrPut(v.chrom, new_seq[region_t]())
    bed_regions[v.chrom].add(v)

  hts.free(kstr.s)
  return bed_regions

iterator window_gen(window: uint32, t: hts.Target): region_t =
  var start:uint32 = 0
  while start + window < t.length:
    yield region_t(chrom: t.name, start: start, stop: start + window)
    start += window
  if start != t.length:
    yield region_t(chrom: t.name, start: start, stop: t.length)

iterator region_gen(window: uint32, target: hts.Target, bed_regions: TableRef[string, seq[region_t]]): region_t =
    if len(bed_regions) == 0:
      for r in window_gen(window, target): yield r
    else:
      if bed_regions.contains(target.name):
        for r in bed_regions[target.name]: yield r
        bed_regions.del(target.name)

proc imean(vals: coverage_t, start:uint32, stop:uint32): float64 =
  if vals == nil or start > uint32(len(vals)):
    return 0
  for i in start .. <stop:
    if int(i) == len(vals): break
    result += float64(vals[int(i)])
  result /= float64(stop-start)

const MAX_COVERAGE = int32(400000)

proc inc(d: var seq[int32], coverage: coverage_t, start:uint32, stop:uint32) =
  var v:int32
  var L = int32(len(d)-1)
  for i in start .. <stop:
    v = coverage[int(i)]
    if v > MAX_COVERAGE:
      v = MAX_COVERAGE - 10
    if v >= L:
      d.set_len(v + 10)
      L = int32(len(d)-1)
    if v < 0: continue
    inc(d[v])

proc write_distribution(chrom: string, d: var seq[int32], fh:File) =
  var sum: int64
  for v in d: sum += int64(v)
  var cum: float64 = 0
  # reverse and then cumsum so that e.g. a value of 1 is the proportion of
  # bases with a coverage of at least 1.
  reverse(d)
  # skip until we see a non-zero value for high-coverage end of array.
  for i, v in pairs(d):
    var irev = len(d) - i - 1
    if irev > 300 and v == 0: continue
    cum += float64(v) / float64(sum)
    if cum < 8e-5: continue
    fh.write_line(chrom, "\t", $irev & "\t" & su.format_float(cum, ffDecimal, precision=4))
  # reverse it back because we use to update the full genome
  reverse(d)

proc get_targets(targets: seq[hts.Target], r: region_t): seq[hts.Target] =
  if r == nil:
    return targets
  result = new_seq[hts.Target](1)
  for t in targets:
    if t.name == r.chrom:
      result[0] = t
      return result

# copy the chromosome array into the genome-wide and then zero it out.
proc copy_and_zero(afrom: var seq[int32], ato: var seq[int32]) =
  if len(afrom) > len(ato):
    ato.set_len(afrom.len)

  for i in 0..<afrom.len:
    ato[i] += afrom[i]
    afrom[i] = 0


proc main(bam: hts.Bam, chrom: region_t, mapq: int, eflag: uint16, region: string, args: Table[string, docopt.Value]) =
  # windows are either from regions, or fixed-length windows.
  # we assume the input is sorted by chrom.
  var
    targets = bam.hdr.targets
    sub_targets = get_targets(targets, chrom)
    rchrom : region_t
    arr: coverage_t
    prefix: string = $(args["<prefix>"])
    skip_per_base = args["--no-per-base"]
    window: uint32 = 0
    bed_regions: TableRef[string, seq[region_t]] = newTable[string, seq[region_t]]()
    fbase: File
    fregion: File
    fh_dist:File

  var distribution = new_seq[int32](1000)
  var chrom_distribution = new_seq[int32](1000)
  if not skip_per_base:
    # TODO: write directly to bgzf.
    discard open(fbase, prefix & ".per-base.txt", fmWrite)

  if not open(fh_dist, prefix & ".mosdepth.dist.txt", fmWrite):
    stderr.write_line("[mosdepth] could not open file:", prefix & ".mosdepth.dist.txt")


  if region != nil:
    # TODO: write directly to bgzf.
    discard open(fregion, prefix & ".regions.bed", fmWrite)
    if region.isdigit():
      window = uint32(S.parse_int(region))
    else:
      bed_regions = bed_gen(region)

  for target in sub_targets:
    # if we can skip per base and there's no regions from this chrom we can avoid coverage calc.
    if skip_per_base and len(bed_regions) != 0 and not bed_regions.contains(target.name):
      continue
    rchrom = region_t(chrom: target.name)
    var j = 0
    for tid in coverage(bam, arr, rchrom, mapq, eflag):
      arr.to_coverage()
      inc(j)
    if j == 0: continue

    var starget = target.name & "\t"
    if region != nil:
      for r in region_gen(window, target, bed_regions):
        var me = imean(arr, r.start, r.stop)
        var m = su.format_float(me, ffDecimal, precision=2)
        if r.name == nil:
          fregion.write_line(starget, intToStr(int(r.start)), "\t", intToStr(int(r.stop)), "\t", m)
        else:
          fregion.write_line(starget, intToStr(int(r.start)), "\t", intToStr(int(r.stop)), "\t", r.name, "\t", m)
        chrom_distribution.inc(arr, r.start, r.stop)
    else:
      chrom_distribution.inc(arr, uint32(0), uint32(len(arr)))

    # write the distribution for each chrom
    write_distribution(target.name, chrom_distribution, fh_dist)
    # then copy it to the genome distribution
    if region == nil:
      copy_and_zero(chrom_distribution, distribution)

    if skip_per_base: continue
    for p in gen_depths(arr, 0, 0, uint32(target.tid)):
      fbase.write_line(starget, intToStr(int(p.stop)), "\t", intToStr(int(p.value)))
  if region == nil:
    write_distribution("genome", distribution, fh_dist)
  for chrom, regions in bed_regions:
    stderr.write_line("[mosdepth] chromosome:", chrom, " from bed with" , len(regions), " not found")
  if fregion != nil: close(fregion)
  if fbase != nil: close(fbase)
  close(fh_dist)

proc check_chrom(r: region_t, targets: seq[Target]) =
  if r == nil: return
  for t in targets:
    if t.name == r.chrom:
      return
  stderr.write_line "[mosdepth] chromosome ", r.chrom, " not found"
  quit(1)

when(isMainModule):
  when not defined(release):
    stderr.write_line "[mosdepth] WARNING: built debug mode. will be slow"

  let version = "mosdepth 0.1.8"
  let doc = format("""
  $version

  Usage: mosdepth [options] <prefix> <BAM-or-CRAM>

Arguments:

  <prefix>       outputs: `{prefix}.mosdepth.dist.txt`
                          `{prefix}.per-base.txt` (unless -n/--no-per-base is specified)
                          `{prefix}.regions.bed` (if --by is specified)

  <BAM-or-CRAM>  the alignment file for which to calculate depth.

Common Options:
  
  -t --threads <threads>     number of BAM decompression threads [default: 0]
  -c --chrom <chrom>         chromosome to restrict depth calculation.
  -b --by <bed|window>       BED file or (integer) window-sizes.
  -n --no-per-base           dont output per-base depth (skipping this output will speed execution).
  -f --fasta <fasta>         fasta file for use with CRAM files.

Other options:

  -F --flag <FLAG>           exclude reads with any of the bits in FLAG set [default: 1796]
  -Q --mapq <mapq>           mapping quality threshold [default: 0]
  -h --help                  show help
  """ % ["version", version])

  let args = docopt(doc, version = version)
  let mapq = S.parse_int($args["--mapq"])
  var region: string
  if $args["--by"] != "nil":
    region = $args["--by"]
  GC_disableMarkAndSweep()
  discard setvbuf(stdout, nil, 0, 16384)
  var fasta: cstring = nil
  if $args["--fasta"] != "nil":
    fasta = cstring($args["--fasta"])

  var
    eflag: uint16 = uint16(S.parse_int($args["--flag"]))
    threads = S.parse_int($args["--threads"])
    chrom = region_line_to_region($args["--chrom"])
    bam = hts.open_hts($args["<BAM-or-CRAM>"], threads=threads, index=true, fai=fasta)
  if bam.idx == nil:
    stderr.write_line("[mosdepth] error alignment file must be indexed")
    quit(2)

  discard bam.set_fields(SamField.SAM_QNAME, SamField.SAM_FLAG, SamField.SAM_RNAME,
                         SamField.SAM_POS, SamField.SAM_MAPQ, SamField.SAM_CIGAR,
                         SamField.SAM_RNEXT, SamField.SAM_PNEXT, SamField.SAM_TLEN,
                         SamField.SAM_QUAL, SamField.SAM_AUX)
  discard bam.set_option(FormatOption.CRAM_OPT_DECODE_MD, 0)
  check_chrom(chrom, bam.hdr.targets)

  main(bam, chrom, mapq, eflag, region, args)
