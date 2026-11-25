## `arvo bench` alternating A/B/A/B benchmark runner enforcing pstack's 7-question
## `/benchmark-checklist` (medians, min-max ranges, error counts, work verification, limiter, honest verdict).
module Bench
expose BenchArgs(..),
SideStats(..),
BenchChecklistReport(..),
BenchTimeouts(..),
default_timeouts,
bench_usage,
parse_bench_args,
compute_stats,
honest_verdict,
run_bench_cmd
use Command
use Json

## Timeout budget used by `arvo bench`.
struct BenchTimeouts
  cmd_secs: Int
  git_secs: Int
  cleanup_secs: Int
end

## Returns default timeout durations for `arvo bench`.
fn default_timeouts() : BenchTimeouts
  BenchTimeouts(cmd_secs: 120, git_secs: 30, cleanup_secs: 15)
end

## Parsed CLI options for `arvo bench`.
struct BenchArgs
  baseline_label: Text
  candidate_label: Text
  baseline_cmd: Text
  candidate_cmd: Text
  runs: Int
  ref_mode?: Bool
  expect_contains: Option(Text)
  limiter: Text
  json?: Bool
  help?: Bool
end

## Aggregate timing and work verification statistics for one side (baseline or candidate).
struct SideStats
  label: Text
  samples_ms: List(Int)
  median_ms: Int
  min_ms: Int
  max_ms: Int
  error_count: Int
  work_verified_runs: Int
end

## Full 7-question `/benchmark-checklist` output structure.
struct BenchChecklistReport
  baseline: SideStats
  candidate: SideStats
  runs_per_side: Int
  alternating_order: Text
  work_happened?: Bool
  limiter: Text
  verdict: Text
  ratio: Float
  summary_note: Text
end

## CLI usage string for `arvo bench`.
fn bench_usage() : Text
  """
    usage: arvo bench [--app DIR] --baseline-cmd CMD --candidate-cmd CMD [flags]
           arvo bench [--app DIR] --baseline REF --candidate REF --cmd CMD [flags]

    Runs alternating A/B/A/B benchmarks and enforces pstack's 7-question benchmark checklist.

    Flags:
      --baseline-cmd CMD     Exact shell command for baseline A
      --candidate-cmd CMD    Exact shell command for candidate B
      --baseline REF         Baseline label (or git ref with --cmd)
      --candidate REF        Candidate label (or git ref with --cmd)
      --cmd CMD              Shared command when comparing two labels/refs
      --runs N               Measured runs per side (default: 7, min: 3)
      --expect-contains STR  Substring required in stdout to prove real work happened
      --limiter TEXT         Measured dominant bottleneck annotation (default: unspecified)
      --json                 Emit JSON report
      -h, --help             Show this help
    """
end

fn need_val(args: List(Text), idx: Int, flag: Text) : Result(Text, Text)
  v = args.get(idx + 1) or ""
  if v.empty? or v.starts_with?("-")
    Error("`#{flag}` requires a value. Run `arvo bench --help`.")
  else
    Ok(v)
  end
end

## Parses arguments after `arvo bench`.
fn parse_bench_args(rest: List(Text)) : Result(BenchArgs, Text)
  var base_lbl = "baseline"
  var cand_lbl = "candidate"
  var base_cmd = ""
  var cand_cmd = ""
  var shared_cmd = ""
  var runs = 7
  var exp = None
  var limiter = "unspecified"
  var json? = false

  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(
        BenchArgs(
          baseline_label: base_lbl,
          candidate_label: cand_lbl,
          baseline_cmd: base_cmd,
          candidate_cmd: cand_cmd,
          runs: runs,
          ref_mode?: false,
          expect_contains: exp,
          limiter: limiter,
          json?: json?,
          help?: true
        )
      )
    else if a == "--baseline-cmd"
      base_cmd = try need_val(rest, i, "--baseline-cmd")
      i += 1
    else if a == "--candidate-cmd"
      cand_cmd = try need_val(rest, i, "--candidate-cmd")
      i += 1
    else if a == "--baseline"
      base_lbl = try need_val(rest, i, "--baseline")
      i += 1
    else if a == "--candidate"
      cand_lbl = try need_val(rest, i, "--candidate")
      i += 1
    else if a == "--cmd"
      shared_cmd = try need_val(rest, i, "--cmd")
      i += 1
    else if a == "--runs"
      raw_r = try need_val(rest, i, "--runs")
      parsed_r = try raw_r.to_int.or_fail("invalid `--runs` integer '#{raw_r}'")
      if parsed_r < 3
        return Error("`--runs` must be at least 3 for a meaningful median & range.")
      end
      runs = parsed_r
      i += 1
    else if a == "--expect-contains"
      exp = Some(try need_val(rest, i, "--expect-contains"))
      i += 1
    else if a == "--limiter"
      limiter = try need_val(rest, i, "--limiter")
      i += 1
    else if a == "--json"
      json? = true
    else
      return Error("unknown flag '#{a}' for `arvo bench`. Run `arvo bench --help`.")
    end
    i += 1
  end

  ref_mode? = base_cmd.empty? and cand_cmd.empty? and not shared_cmd.empty? and
    base_lbl != "baseline" and
    cand_lbl != "candidate"
  eff_base = if base_cmd.empty?: shared_cmd else: base_cmd
  eff_cand = if cand_cmd.empty?: shared_cmd else: cand_cmd
  if eff_base.empty? or eff_cand.empty?
    return Error("`arvo bench` requires `--baseline-cmd`/`--candidate-cmd` (or `--cmd`). Run `arvo bench --help`.")
  end
  Ok(
    BenchArgs(
      baseline_label: base_lbl,
      candidate_label: cand_lbl,
      baseline_cmd: eff_base,
      candidate_cmd: eff_cand,
      runs: runs,
      ref_mode?: ref_mode?,
      expect_contains: exp,
      limiter: limiter,
      json?: json?,
      help?: false
    )
  )
end

## Computes sorted median and min-max range for one benchmark side.
fn compute_stats(
  label: Text,
  samples_ms: List(Int),
  error_count: Int,
  work_verified_runs: Int
) : SideStats
  sorted = samples_ms.sort
  case sorted.first
    None:
      SideStats(
        label: label,
        samples_ms: samples_ms,
        median_ms: 0,
        min_ms: 0,
        max_ms: 0,
        error_count: error_count,
        work_verified_runs: work_verified_runs
      )
    Some(min_v):
      max_v = sorted.last or min_v
      n = sorted.size
      med = if n.floor_mod(2) == 1
        sorted.get(n.floor_div(2)) or min_v
      else
        lo = sorted.get(n.floor_div(2) - 1) or min_v
        hi = sorted.get(n.floor_div(2)) or min_v
        (lo + hi).floor_div(2)
      end
      SideStats(
        label: label,
        samples_ms: samples_ms,
        median_ms: med,
        min_ms: min_v,
        max_ms: max_v,
        error_count: error_count,
        work_verified_runs: work_verified_runs
      )
  end
end

## Computes the honest 7-question checklist verdict (`faster | slower | no_difference | inconclusive`).
fn honest_verdict(base: SideStats, cand: SideStats, runs_per_side: Int) : (Text, Float, Text)
  if base.error_count > 0 or
    cand.error_count > 0 or
    base.work_verified_runs < runs_per_side or
    cand.work_verified_runs < runs_per_side
    return (
      "inconclusive",
      1.0,
      "errors or unverified work prevented a valid comparison (base_err=#{base.error_count}, cand_err=#{cand.error_count})"
    )
  end

  if base.median_ms <= 0
    return ("no_difference", 1.0, "sub-millisecond baseline median (ranges overlap at measurement floor)")
  end

  ratio = cand.median_ms.to_float / base.median_ms.to_float
  ranges_overlap? = cand.min_ms <= base.max_ms and base.min_ms <= cand.max_ms
  if ranges_overlap?
    (
      "no_difference",
      ratio,
      "ranges overlap (base=#{base.median_ms}ms [#{base.min_ms}..#{base.max_ms}], cand=#{cand.median_ms}ms [#{cand.min_ms}..#{cand.max_ms}])"
    )
  else if cand.median_ms * 20 <= base.median_ms * 19
    (
      "faster",
      ratio,
      "candidate median #{cand.median_ms}ms faster than baseline #{base.median_ms}ms with non-overlapping ranges"
    )
  else if cand.median_ms * 20 >= base.median_ms * 21
    (
      "slower",
      ratio,
      "candidate median #{cand.median_ms}ms slower than baseline #{base.median_ms}ms with non-overlapping ranges"
    )
  else
    (
      "no_difference",
      ratio,
      "median difference <5% (base=#{base.median_ms}ms, cand=#{cand.median_ms}ms)"
    )
  end
end

fn elapsed_ms(clock: Clock, started: Time) : Int
  ms = (clock.now - started).in_milliseconds
  if ms >= 1: ms else: 0
end

fn run_one_sample(
  shell_cmd: Text,
  expect_contains: Option(Text),
  cmd: Command,
  clock: Clock
) : (Int, Bool, Bool)
  t = default_timeouts()
  t0 = clock.now
  res = cmd.run("sh", ["-c", shell_cmd], t.cmd_secs.seconds)
  ms = elapsed_ms(clock, t0)
  case res
    Error(_): (ms, false, false)
    Ok(out):
      if not out.ok?
        (ms, false, false)
      else
        work_ok? = case expect_contains
          Some(needle): out.stdout.contains?(needle) or out.stderr.contains?(needle)
          None: not out.stdout.trim.empty? or not out.stderr.trim.empty?
        end
        (ms, true, work_ok?)
      end
  end
end

fn prepare_ref_worktrees(base_ref: Text, cand_ref: Text, cmd: Command) : Result((Text, Text), Text)
  t = default_timeouts()
  wt_a = ".arvo/tmp/bench_a"
  wt_b = ".arvo/tmp/bench_b"
  _r1 = cmd.run("git", ["worktree", "remove", "--force", wt_a], t.cleanup_secs.seconds)
  _r2 = cmd.run("git", ["worktree", "remove", "--force", wt_b], t.cleanup_secs.seconds)
  a_out = try cmd.run("git", ["worktree", "add", "--detach", wt_a, base_ref], t.git_secs.seconds)
    .map_error(fn(e) "git worktree add #{base_ref} failed: #{e}" end)
  if not a_out.ok?
    return Error("git worktree add #{base_ref} failed: #{a_out.stderr.trim}")
  end
  b_out = try cmd.run("git", ["worktree", "add", "--detach", wt_b, cand_ref], t.git_secs.seconds)
    .map_error(fn(e) "git worktree add #{cand_ref} failed: #{e}" end)
  if not b_out.ok?
    _rm = cmd.run("git", ["worktree", "remove", "--force", wt_a], t.cleanup_secs.seconds)
    return Error("git worktree add #{cand_ref} failed: #{b_out.stderr.trim}")
  end
  Ok((wt_a, wt_b))
end

fn cleanup_ref_worktrees(cmd: Command) : Bool
  t = default_timeouts()
  ok1 = case cmd.run("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_a"], t.cleanup_secs.seconds)
    Ok(o): o.ok?
    Error(_): false
  end
  ok2 = case cmd.run("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_b"], t.cleanup_secs.seconds)
    Ok(o): o.ok?
    Error(_): false
  end
  ok1 and ok2
end

## Executes alternating A/B/A/B benchmark runs and outputs checklist results.
fn run_bench_cmd(bargs: BenchArgs, cmd: Command, clock: Clock, console: Console) : Int
  if bargs.help?
    console.print(bench_usage())
    return 0
  end

  (run_base_cmd, run_cand_cmd) = if bargs.ref_mode?
    case prepare_ref_worktrees(bargs.baseline_label, bargs.candidate_label, cmd)
      Ok((wa, wb)): (
        "cd \"#{wa}\" && #{bargs.baseline_cmd}",
        "cd \"#{wb}\" && #{bargs.candidate_cmd}"
      )
      Error(e):
        console.error("arvo bench: #{e}")
        return 1
    end
  else
    (bargs.baseline_cmd, bargs.candidate_cmd)
  end

  var a_samples = []
  var b_samples = []
  var a_errs = 0
  var b_errs = 0
  var a_work = 0
  var b_work = 0

  var i = 0
  while i < bargs.runs
    (a_ms, a_ok?, a_w?) = run_one_sample(run_base_cmd, bargs.expect_contains, cmd, clock)
    a_samples = a_samples.append(a_ms)
    if not a_ok?
      a_errs += 1
    end
    if a_w?
      a_work += 1
    end

    (b_ms, b_ok?, b_w?) = run_one_sample(run_cand_cmd, bargs.expect_contains, cmd, clock)
    b_samples = b_samples.append(b_ms)
    if not b_ok?
      b_errs += 1
    end
    if b_w?
      b_work += 1
    end
    i += 1
  end

  base_stats = compute_stats(bargs.baseline_label, a_samples, a_errs, a_work)
  cand_stats = compute_stats(bargs.candidate_label, b_samples, b_errs, b_work)
  (verdict, ratio, note) = honest_verdict(base_stats, cand_stats, bargs.runs)
  work_all? = a_work == bargs.runs and b_work == bargs.runs

  if bargs.json?
    doc = Json.Object({
      "verdict": Json.String(verdict),
      "ratio": Json.float(ratio) or Json.Null,
      "runs_per_side": Json.int(bargs.runs),
      "alternating_order": Json.String("A/B/A/B"),
      "work_happened": Json.Boolean(work_all?),
      "limiter": Json.String(bargs.limiter),
      "note": Json.String(note),
      "baseline": Json.Object({
        "label": Json.String(base_stats.label),
        "median_ms": Json.int(base_stats.median_ms),
        "min_ms": Json.int(base_stats.min_ms),
        "max_ms": Json.int(base_stats.max_ms),
        "errors": Json.int(base_stats.error_count),
        "work_verified_runs": Json.int(base_stats.work_verified_runs)
      }),
      "candidate": Json.Object({
        "label": Json.String(cand_stats.label),
        "median_ms": Json.int(cand_stats.median_ms),
        "min_ms": Json.int(cand_stats.min_ms),
        "max_ms": Json.int(cand_stats.max_ms),
        "errors": Json.int(cand_stats.error_count),
        "work_verified_runs": Json.int(cand_stats.work_verified_runs)
      })
    })
    console.print(doc.to_text)
  else
    lines = [
      "Arvo Bench (7-question checklist) => #{verdict}",
      "  Order: alternating A/B/A/B (#{bargs.runs} runs/side)",
      "  #{base_stats.label}: median=#{base_stats.median_ms}ms range=[#{base_stats.min_ms}..#{base_stats.max_ms}]ms errors=#{base_stats.error_count} work=#{base_stats.work_verified_runs}/#{bargs.runs}",
      "  #{cand_stats.label}: median=#{cand_stats.median_ms}ms range=[#{cand_stats.min_ms}..#{cand_stats.max_ms}]ms errors=#{cand_stats.error_count} work=#{cand_stats.work_verified_runs}/#{bargs.runs}",
      "  Limiter: #{bargs.limiter}",
      "  Notes: #{note}"
    ]
    console.print(lines.join("\n"))
  end

  if bargs.ref_mode?
    if not cleanup_ref_worktrees(cmd)
      console.error("arvo bench: failed removing temporary benchmark worktrees")
    end
  end
  if verdict == "inconclusive": 1 else: 0
end

test "Bench parses args, enforces 7-question checklist honesty, and computes alternating medians"
  dt = default_timeouts()
  assert dt.cmd_secs == 120 and dt.git_secs == 30 and dt.cleanup_secs == 15
  t0 = Time.parse("2026-11-25T23:10:00Z") or stop "t0"
  assert elapsed_ms(Clock.fixed(t0 - 1.millisecond), t0) == 0
  assert elapsed_ms(Clock.fixed(t0), t0) == 0
  assert elapsed_ms(Clock.fixed(t0 + 1.millisecond), t0) == 1
  assert elapsed_ms(Clock.fixed(t0 + 5.milliseconds), t0) == 5

  assert parse_bench_args([]) is Error(_)
  assert parse_bench_args(["--help"]) is Ok(h) and h.help? and not h.ref_mode?
  assert parse_bench_args(["-h"]) is Ok(h2) and h2.help? and not h2.ref_mode?
  assert parse_bench_args(["--baseline", "base1", "--help"]) is Ok(h3) and
    h3.baseline_label == "base1" and
    h3.help? and
    not h3.ref_mode?
  assert parse_bench_args(["--cmd", "-bad"]) is Error(_)
  assert parse_bench_args(["--baseline", "a", "--cmd", "echo x"]) is Ok(def_b) and
    def_b.runs == 7 and
    not def_b.json? and
    not def_b.ref_mode?
  assert parse_bench_args(["--candidate", "b", "--cmd", "echo x"]) is Ok(def_c) and
    not def_c.ref_mode?
  assert parse_bench_args(["--baseline-cmd", "echo a"]) is Error(_)
  assert parse_bench_args(["--candidate-cmd", "echo b"]) is Error(_)
  assert parse_bench_args(["--baseline-cmd", "echo a", "--candidate-cmd", "echo b", "--runs", "2"]) is
    Error(_)
  assert parse_bench_args(["--cmd", "echo a", "--runs", "bad"]) is Error(_)
  assert parse_bench_args(["--cmd", "echo a", "--bad"]) is Error(_)
  assert parse_bench_args(["--cmd"]) is Error(_)

  s_base = compute_stats("A", [100, 110, 105], 0, 3)
  assert s_base.median_ms == 105 and s_base.min_ms == 100 and s_base.max_ms == 110
  s5 = compute_stats("5", [10, 50, 20, 40, 30], 0, 5)
  assert s5.median_ms == 30
  s_cand_fast = compute_stats("B", [50, 55, 60], 0, 3)
  v_fast = honest_verdict(s_base, s_cand_fast, 3)
  assert v_fast.0 == "faster" and v_fast.1 > 0.4 and v_fast.1 < 0.6
  assert honest_verdict(
    compute_stats("A", [100, 100, 100], 0, 3),
    compute_stats("B", [50, 50, 50], 0, 3),
    3
  ).1 ==
    0.5
  s_cand_slow = compute_stats("B", [150, 160, 155], 0, 3)
  assert honest_verdict(s_base, s_cand_slow, 3).0 == "slower"
  assert honest_verdict(s_base, compute_stats("B", [105, 105, 105], 0, 3), 3).0 == "no_difference"
  assert honest_verdict(
    compute_stats("A", [100, 110, 105], 0, 3),
    compute_stats("B", [110, 120, 115], 0, 3),
    3
  ).0 ==
    "no_difference"
  assert honest_verdict(
    compute_stats("A", [110, 120, 115], 0, 3),
    compute_stats("B", [100, 110, 105], 0, 3),
    3
  ).0 ==
    "no_difference"
  assert honest_verdict(
    compute_stats("A", [100, 100, 100], 0, 3),
    compute_stats("B", [96, 96, 96], 0, 3),
    3
  ).0 ==
    "no_difference"
  assert honest_verdict(
    compute_stats("A", [100, 100, 100], 0, 3),
    compute_stats("B", [95, 95, 95], 0, 3),
    3
  ).0 ==
    "faster"
  assert honest_verdict(
    compute_stats("A", [100, 100, 100], 0, 3),
    compute_stats("B", [104, 104, 104], 0, 3),
    3
  ).0 ==
    "no_difference"
  assert honest_verdict(
    compute_stats("A", [100, 100, 100], 0, 3),
    compute_stats("B", [105, 105, 105], 0, 3),
    3
  ).0 ==
    "slower"
  assert honest_verdict(compute_stats("A", [1, 1, 1], 0, 3), compute_stats("B", [10, 10, 10], 0, 3), 3).0 ==
    "slower"
  assert honest_verdict(compute_stats("A", [10, 20, 30], 1, 3), s_cand_fast, 3).0 == "inconclusive"
  assert honest_verdict(s_base, compute_stats("B", [10, 20, 30], 1, 3), 3).0 == "inconclusive"
  assert honest_verdict(compute_stats("A", [10, 20, 30], 0, 2), s_cand_fast, 3).0 == "inconclusive"
  assert honest_verdict(s_base, compute_stats("B", [10, 20, 30], 0, 2), 3).0 == "inconclusive"
  assert honest_verdict(compute_stats("A", [0, 0, 0], 0, 3), s_cand_fast, 3).0 == "no_difference"
  s_empty = compute_stats("E", [], 0, 0)
  assert s_empty.median_ms == 0 and s_empty.min_ms == 0 and s_empty.max_ms == 0
  assert compute_stats("Ev", [10, 20, 30, 40], 0, 4).median_ms == 25

  rep = Command.replies([
    (Command.spec("sh", ["-c", "echo okA"]), Command.ok_output("okA\n")),
    (Command.spec("sh", ["-c", "echo okB"]), Command.ok_output("okB\n")),
    (Command.spec("sh", ["-c", "echo erronly"]), Command.output(0, "", "warn\n")),
    (Command.spec("sh", ["-c", "echo empty"]), Command.ok_output("   \n")),
    (Command.spec("sh", ["-c", "echo wrong"]), Command.ok_output("other\n")),
    (Command.spec("sh", ["-c", "false"]), Command.output(1, "", "err"))
  ])
  assert parse_bench_args([
    "--expect-contains",
    "ok",
    "--limiter",
    "sqlite-io",
    "--baseline",
    "old",
    "--candidate",
    "new",
    "--baseline-cmd",
    "echo okA",
    "--candidate-cmd",
    "echo okB",
    "--runs",
    "3",
    "--json"
  ]) is
    Ok(args_ok)
  c_json = Console.fake()
  assert run_bench_cmd(args_ok, Command.fake(rep), Clock.fixed(t0), c_json) == 0
  assert (c_json.printed.first or "").contains?("\"verdict\":\"no_difference\"")
  assert (c_json.printed.first or "").contains?("\"work_happened\":true")
  assert c_json.printed_errors.empty?

  # Work verified without expect-contains checks non-empty stdout or stderr
  assert parse_bench_args([
    "--baseline-cmd",
    "echo erronly",
    "--candidate-cmd",
    "echo empty",
    "--runs",
    "3",
    "--json"
  ]) is
    Ok(args_w)
  c_w = Console.fake()
  assert run_bench_cmd(args_w, Command.fake(rep), Clock.fixed(t0), c_w) == 1
  assert Json.parse(c_w.printed.first or "") is Ok(w_doc)
  assert w_doc.int_at("baseline.work_verified_runs") == Some(3)
  assert w_doc.int_at("candidate.work_verified_runs") == Some(0)

  # Baseline failure & blocked command count exact errors & work=0 on failing side
  args_txt = BenchArgs(
    baseline_label: "A",
    candidate_label: "B",
    baseline_cmd: "false",
    candidate_cmd: "echo okB",
    runs: 3,
    ref_mode?: false,
    expect_contains: Some("okB"),
    limiter: "cpu",
    json?: true,
    help?: false
  )
  c_base_err = Console.fake()
  assert run_bench_cmd(args_txt, Command.fake(rep), Clock.fixed(t0), c_base_err) == 1
  assert Json.parse(c_base_err.printed.first or "") is Ok(be_doc)
  assert be_doc.int_at("baseline.errors") == Some(3) and
    be_doc.int_at("baseline.work_verified_runs") == Some(0) and
    be_doc.int_at("candidate.errors") == Some(0) and
    be_doc.int_at("candidate.work_verified_runs") == Some(3)

  c_perm_err = Console.fake()
  assert run_bench_cmd(
    args_txt,
    Command.fake(rep).allow_programs([]),
    Clock.fixed(t0),
    c_perm_err
  ) ==
    1
  assert (c_perm_err.printed.first or "").split("\"errors\":3").size == 3 and
    (c_perm_err.printed.first or "").split("\"work_verified_runs\":0").size == 3

  c_plain = Console.fake()
  assert run_bench_cmd(
    BenchArgs(
      baseline_label: "A",
      candidate_label: "B",
      baseline_cmd: "echo okA",
      candidate_cmd: "false",
      runs: 3,
      ref_mode?: false,
      expect_contains: Some("okA"),
      limiter: "cpu",
      json?: false,
      help?: false
    ),
    Command.fake(rep),
    Clock.fixed(t0),
    c_plain
  ) ==
    1
  assert (c_plain.printed.first or "").contains?("=> inconclusive")

  args_miss = BenchArgs(
    baseline_label: "A",
    candidate_label: "B",
    baseline_cmd: "echo wrong",
    candidate_cmd: "echo okB",
    runs: 3,
    ref_mode?: false,
    expect_contains: Some("okB"),
    limiter: "cpu",
    json?: true,
    help?: false
  )
  c_miss = Console.fake()
  assert run_bench_cmd(args_miss, Command.fake(rep), Clock.fixed(t0), c_miss) == 1
  assert (c_miss.printed.first or "").contains?("\"work_happened\":false")

  c_help = Console.fake()
  assert run_bench_cmd(
    BenchArgs(
      baseline_label: "a",
      candidate_label: "b",
      baseline_cmd: "c",
      candidate_cmd: "d",
      runs: 3,
      ref_mode?: false,
      expect_contains: None,
      limiter: "x",
      json?: false,
      help?: true
    ),
    Command.fake(rep),
    Clock.fixed(t0),
    c_help
  ) ==
    0
  assert (c_help.printed.first or "").contains?("7-question")

  # Ref-based worktree mode prepares two worktrees and cleans up, or errors cleanly
  rep_wt = Command.replies([
    (
      Command.spec("git", ["worktree", "add", "--detach", ".arvo/tmp/bench_a", "HEAD~1"]),
      Command.ok_output("")
    ),
    (
      Command.spec("git", ["worktree", "add", "--detach", ".arvo/tmp/bench_b", "HEAD"]),
      Command.ok_output("")
    ),
    (
      Command.spec("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_a"]),
      Command.ok_output("")
    ),
    (
      Command.spec("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_b"]),
      Command.ok_output("")
    ),
    (Command.spec("sh", ["-c", "cd \".arvo/tmp/bench_a\" && echo hi"]), Command.ok_output("hi\n")),
    (Command.spec("sh", ["-c", "cd \".arvo/tmp/bench_b\" && echo hi"]), Command.ok_output("hi\n"))
  ])
  assert parse_bench_args([
    "--baseline",
    "HEAD~1",
    "--candidate",
    "HEAD",
    "--cmd",
    "echo hi",
    "--runs",
    "3",
    "--json"
  ]) is
    Ok(args_ref)
  assert args_ref.ref_mode?
  c_ref = Console.fake()
  assert run_bench_cmd(args_ref, Command.fake(rep_wt), Clock.fixed(t0), c_ref) == 0
  assert c_ref.printed_errors.empty?
  assert run_bench_cmd(
    args_ref,
    Command.fake(Command.replies([])).allow_programs([]),
    Clock.fixed(t0),
    Console.fake()
  ) ==
    1

  # Second ref failure cleans up first worktree and fails cleanly
  rep_wt_fail2 = Command.replies([
    (
      Command.spec("git", ["worktree", "add", "--detach", ".arvo/tmp/bench_a", "HEAD~1"]),
      Command.ok_output("")
    ),
    (
      Command.spec("git", ["worktree", "add", "--detach", ".arvo/tmp/bench_b", "HEAD"]),
      Command.output(1, "", "bad ref")
    ),
    (
      Command.spec("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_a"]),
      Command.ok_output("")
    )
  ])
  assert run_bench_cmd(args_ref, Command.fake(rep_wt_fail2), Clock.fixed(t0), Console.fake()) == 1

  # Cleanup failure emits error log (covers ok1/ok2 branches and ref cleanup call)
  rep_wt_bad_rm = Command.replies([
    (
      Command.spec("git", ["worktree", "add", "--detach", ".arvo/tmp/bench_a", "HEAD~1"]),
      Command.ok_output("")
    ),
    (
      Command.spec("git", ["worktree", "add", "--detach", ".arvo/tmp/bench_b", "HEAD"]),
      Command.ok_output("")
    ),
    (
      Command.spec("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_a"]),
      Command.ok_output("")
    ),
    (
      Command.spec("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_b"]),
      Command.output(1, "", "locked")
    ),
    (Command.spec("sh", ["-c", "cd \".arvo/tmp/bench_a\" && echo hi"]), Command.ok_output("hi\n")),
    (Command.spec("sh", ["-c", "cd \".arvo/tmp/bench_b\" && echo hi"]), Command.ok_output("hi\n"))
  ])
  c_bad_rm = Console.fake()
  assert run_bench_cmd(args_ref, Command.fake(rep_wt_bad_rm), Clock.fixed(t0), c_bad_rm) == 0
  assert c_bad_rm.printed_errors.any?(fn(e) e.contains?("failed removing temporary") end)

  assert not cleanup_ref_worktrees(
    Command.fake(
      Command.replies([
        (
          Command.spec("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_a"]),
          Command.output(1, "", "no")
        ),
        (
          Command.spec("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_b"]),
          Command.ok_output("")
        )
      ])
    )
  )
  assert not cleanup_ref_worktrees(
    Command.fake(
      Command.replies([
        (
          Command.spec("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_b"]),
          Command.ok_output("")
        )
      ])
    )
  )
  assert not cleanup_ref_worktrees(
    Command.fake(
      Command.replies([
        (
          Command.spec("git", ["worktree", "remove", "--force", ".arvo/tmp/bench_a"]),
          Command.ok_output("")
        )
      ])
    )
  )
end
