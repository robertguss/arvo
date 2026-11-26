## `arvo statechart` command and `arvo verify --tier full` statechart phase.
## Explores `Arvo.Jobs` and `Arvo.Session`, checks sync commits and optional `.tla` specs,
## proves negative broken variants fail, runs real-code replay, and emits Mermaid + JSON reports.
module StatechartCmd
expose StatechartArgs(..),
StatechartTimeouts(..),
default_timeouts,
statechart_usage,
parse_statechart_args,
extract_covered_file_paths,
check_sync_commit,
find_tla_files,
run_statechart_cmd,
run_statechart_phase
use Arvo.Statechart
use Command
use Dossier
use Json

## Parsed `arvo statechart` arguments.
struct StatechartArgs
  subcmd: Text
  out_dir: Option(Text)
  tla_file: Option(Text)
  help?: Bool
end

## Timeouts used by `arvo statechart`.
struct StatechartTimeouts
  git_secs: Int
  mo_secs: Int
  tlc_secs: Int
end

fn default_timeouts() : StatechartTimeouts
  StatechartTimeouts(git_secs: 15, mo_secs: 60, tlc_secs: 120)
end

## Usage text for `arvo statechart`.
fn statechart_usage() : Text
  """
    usage: arvo statechart [check|render] [--app DIR] [--out DIR] [--tla FILE]

    Runs bounded BFS exploration on Arvo.Jobs and Arvo.Session, verifies real-code replay
    and sync commits, checks broken variants still fail, and writes Mermaid + JSON reports.

    Flags:
      --out DIR   Output directory (default: .arvo/dossier/statecharts)
      --tla FILE  Optional TLA+ specification to run with `tlc`
      -h, --help  Show this help
    """
end

fn need_flag_val(args: List(Text), idx: Int, flag: Text) : Result(Text, Text)
  v = args.get(idx + 1) or ""
  if v.empty? or v.starts_with?("-")
    Error("`#{flag}` requires a value. Run `arvo statechart --help`.")
  else
    Ok(v)
  end
end

## Parses arguments after `arvo statechart`.
fn parse_statechart_args(rest: List(Text)) : Result(StatechartArgs, Text)
  var subcmd = "check"
  var seen_sub? = false
  var out_dir = None
  var tla_file = None
  var i = 0
  while i < rest.size
    a = rest.get(i) or ""
    if a == "--help" or a == "-h"
      return Ok(StatechartArgs(subcmd: subcmd, out_dir: out_dir, tla_file: tla_file, help?: true))
    else if a == "--out"
      out_dir = Some(try need_flag_val(rest, i, "--out"))
      i += 1
    else if a == "--tla"
      tla_file = Some(try need_flag_val(rest, i, "--tla"))
      i += 1
    else if (a == "check" or a == "render") and not seen_sub?
      subcmd = a
      seen_sub? = true
    else
      return Error("unknown argument '#{a}' for `arvo statechart`. Run `arvo statechart --help`.")
    end
    i += 1
  end
  Ok(StatechartArgs(subcmd: subcmd, out_dir: out_dir, tla_file: tla_file, help?: false))
end

## Extracts plain file paths from `file.mo:fn1,fn2` specs.
fn extract_covered_file_paths(covered_files: List(Text)) : List(Text)
  var out = []
  for raw in covered_files
    base = (raw.split(":").first or "").trim
    if not base.empty? and not out.contains?(base)
      out = out.append(base)
    end
  end
  out
end

## Checks whether `covered_files` have changed since `sync_commit` (`in_sync` vs `STALE_FORMAL_CHECK`).
fn check_sync_commit(
  covered_files: List(Text),
  sync_commit: Text,
  cmd: Command,
  env: Env
) : (Bool, Text)
  t = default_timeouts()
  short_sha = Text.from_chars(sync_commit.chars.take(8))
  base_files = extract_covered_file_paths(covered_files)
  return (true, "in_sync (#{short_sha})") if base_files.empty?

  # Include both committed changes and uncommitted working-tree changes since `sync_commit`.
  git_args = ["diff", "--name-only", sync_commit, "--"].concat(base_files)
  case cmd.run("git", git_args, t.git_secs.seconds)
    Ok(out):
      if out.ok?
        changed = out.stdout.lines.map(fn(l) l.trim end).filter(fn(l) not l.empty? end)
        if not changed.empty?
          return (false, "STALE_FORMAL_CHECK: changed since #{short_sha}: #{changed.join(", ")}")
        end
        return (true, "in_sync (#{short_sha})")
      end
    Error(_): Unit
  end

  if env.get("ARVO_GIT_DIFF_FILES") is Some(raw_diff)
    changed_env = raw_diff.replace(",", "\n").lines.map(fn(l) l.trim end).filter(
      fn(l) not l.empty? end
    )
    hits = base_files.filter(fn(p) changed_env.contains?(p) end)
    if not hits.empty?
      return (false, "STALE_FORMAL_CHECK: changed since #{short_sha}: #{hits.join(", ")}")
    end
    return (true, "in_sync (#{short_sha}; env)")
  end
  (
    false,
    "STALE_FORMAL_CHECK: git diff failed for #{short_sha}; ensure git history is intact or update sync_commit"
  )
end

## Discovers `.tla` formal specs under `specs/formal` when present.
fn find_tla_files(files: ReadFiles, explicit: Option(Text)) : List(Text)
  case explicit
    Some(p): [p]
    None:
      case files.walk("specs/formal")
        Error(_): []
        Ok(ents):
          ents.filter_map(fn(e)
            if e.kind is File and e.name.ends_with?(".tla")
              Some("specs/formal/#{e.name}")
            else
              None
            end
          end).sort
      end
  end
end

fn run_tla_specs(tla_paths: List(Text), cmd: Command) : (Bool, List(Text))
  t = default_timeouts()
  var all_ok? = true
  var details = []
  for p in tla_paths
    case cmd.run("tlc", ["-cleanup", p], t.tlc_secs.seconds)
      Ok(out):
        if out.ok?
          details = details.append("#{p}: pass")
        else
          all_ok? = false
          details = details.append("#{p}: fail (#{out.stderr.trim})")
        end
      Error(err):
        all_ok? = false
        details = details.append("#{p}: tlc unavailable (#{err})")
    end
  end
  (all_ok?, details)
end

fn run_replay_suite(cmd: Command) : (Bool, Text)
  t = default_timeouts()
  case cmd.run("mo", ["test", "--json", "lib/arvo/statechart.mo"], t.mo_secs.seconds)
    Error(err): (false, "statechart replay suite failed to run: #{err}")
    Ok(out):
      sum = Dossier.parse_mo_test_json(out.stdout)
      if out.ok? and sum.failed == 0 and sum.stopped == 0 and sum.errors == 0 and sum.passed > 0
        (true, "replay passed (#{sum.passed} check(s))")
      else
        (false, "replay failed (passed=#{sum.passed}, failed=#{sum.failed + sum.stopped}, errors=#{sum.errors})")
      end
  end
end

struct SingleChartOutcome
  title: Text
  slug: Text
  states: Int
  transitions: Int
  truncated?: Bool
  violations: Int
  in_sync?: Bool
  sync_detail: Text
  broken_caught?: Bool
  covered_files: List(Text)
  sync_commit: Text
  mmd_path: Text
  report_md: Text
  mermaid_mmd: Text
end

fn outcome_to_json(o: SingleChartOutcome) : Json
  Json.Object({
    "title": Json.String(o.title),
    "slug": Json.String(o.slug),
    "states": Json.int(o.states),
    "transitions": Json.int(o.transitions),
    "truncated": Json.Boolean(o.truncated?),
    "violations": Json.int(o.violations),
    "in_sync": Json.Boolean(o.in_sync?),
    "sync_detail": Json.String(o.sync_detail),
    "broken_caught": Json.Boolean(o.broken_caught?),
    "covered_files": o.covered_files.to_json,
    "sync_commit": Json.String(o.sync_commit),
    "mmd_path": Json.String(o.mmd_path),
    "mermaid": Json.String(o.mermaid_mmd)
  })
end

fn evaluate_and_write(
  out_dir: Text,
  files: Files,
  cmd: Command,
  env: Env,
  tla_opt: Option(Text)
) : Result((Bool, Int, Int, List(SingleChartOutcome), Text, List(Text)), Text)
  try files.make_folder(out_dir).map_error(fn(e) "failed creating #{out_dir}: #{e}" end)

  j_spec = Statechart.jobs_chart_spec()
  j_rep = Statechart.explore(j_spec)
  j_broken = Statechart.explore(Statechart.broken_jobs_chart_spec())
  (j_sync?, j_sync_msg) = check_sync_commit(j_spec.covered_files, j_spec.sync_commit, cmd, env)
  j_mmd_path = "#{out_dir}/jobs.mmd"
  try files.write_text(j_mmd_path, j_rep.mermaid_mmd).map_error(
    fn(e) "failed writing #{j_mmd_path}: #{e}" end
  )

  s_spec = Statechart.session_chart_spec()
  s_rep = Statechart.explore(s_spec)
  s_broken = Statechart.explore(Statechart.broken_session_chart_spec())
  (s_sync?, s_sync_msg) = check_sync_commit(s_spec.covered_files, s_spec.sync_commit, cmd, env)
  s_mmd_path = "#{out_dir}/session.mmd"
  try files.write_text(s_mmd_path, s_rep.mermaid_mmd).map_error(
    fn(e) "failed writing #{s_mmd_path}: #{e}" end
  )

  (replay_ok?, replay_msg) = run_replay_suite(cmd)
  tla_paths = find_tla_files(files.read_only, tla_opt)
  (tla_ok?, tla_msgs) = if tla_paths.empty?: (true, []) else: run_tla_specs(tla_paths, cmd)

  outcomes = [
    SingleChartOutcome(
      title: j_spec.title,
      slug: "jobs",
      states: j_rep.states_explored,
      transitions: j_rep.transitions_explored,
      truncated?: j_rep.truncated?,
      violations: j_rep.violations.size,
      in_sync?: j_sync?,
      sync_detail: j_sync_msg,
      broken_caught?: not j_broken.violations.empty?,
      covered_files: j_spec.covered_files,
      sync_commit: j_spec.sync_commit,
      mmd_path: j_mmd_path,
      report_md: Statechart.format_report(j_spec, j_rep),
      mermaid_mmd: j_rep.mermaid_mmd
    ),
    SingleChartOutcome(
      title: s_spec.title,
      slug: "session",
      states: s_rep.states_explored,
      transitions: s_rep.transitions_explored,
      truncated?: s_rep.truncated?,
      violations: s_rep.violations.size,
      in_sync?: s_sync?,
      sync_detail: s_sync_msg,
      broken_caught?: not s_broken.violations.empty?,
      covered_files: s_spec.covered_files,
      sync_commit: s_spec.sync_commit,
      mmd_path: s_mmd_path,
      report_md: Statechart.format_report(s_spec, s_rep),
      mermaid_mmd: s_rep.mermaid_mmd
    )
  ]

  total_states = j_rep.states_explored + s_rep.states_explored
  total_transitions = j_rep.transitions_explored + s_rep.transitions_explored
  charts_ok? = j_rep.violations.empty? and
    s_rep.violations.empty? and
    not j_rep.truncated? and
    not s_rep.truncated? and
    j_sync? and
    s_sync? and
    not j_broken.violations.empty? and
    not s_broken.violations.empty? and
    replay_ok? and
    tla_ok?

  full_md = [
    outcomes.map(fn(o) o.report_md end).join("\n"),
    "- Replay check: #{replay_msg}",
    if tla_msgs.empty?: "" else: "- TLA+ check: #{tla_msgs.join("; ")}"
  ].filter(fn(s) not s.empty? end).join("\n")
  _w_md = try files.write_text("#{out_dir}/report.md", "#{full_md}\n").map_error(
    fn(e) "failed writing #{out_dir}/report.md: #{e}" end
  )
  report_json = Json.Object({
    "ok": Json.Boolean(charts_ok?),
    "states_explored": Json.int(total_states),
    "transitions_explored": Json.int(total_transitions),
    "replay_ok": Json.Boolean(replay_ok?),
    "replay_detail": Json.String(replay_msg),
    "tla_ok": Json.Boolean(tla_ok?),
    "tla_details": tla_msgs.to_json,
    "charts": Json.Array(outcomes.map(outcome_to_json))
  })
  _w_json = try files.write_text("#{out_dir}/report.json", "#{report_json.pretty}\n").map_error(
    fn(e) "failed writing #{out_dir}/report.json: #{e}" end
  )
  Ok((charts_ok?, total_states, total_transitions, outcomes, replay_msg, tla_msgs))
end

fn elapsed_ms(clock: Clock, started: Time) : Int
  ms = (clock.now - started).in_milliseconds
  if ms >= 1: ms else: 0
end

## Executes `arvo statechart [check|render]`.
fn run_statechart_cmd(
  sargs: StatechartArgs,
  files: Files,
  cmd: Command,
  env: Env,
  console: Console
) : Int
  if sargs.help?
    console.print(statechart_usage())
    return 0
  end
  out_dir = sargs.out_dir or ".arvo/dossier/statecharts"
  case evaluate_and_write(out_dir, files, cmd, env, sargs.tla_file)
    Error(err):
      console.error("arvo statechart: #{err}")
      1
    Ok((ok?, states, transitions, outcomes, replay_msg, tla_msgs)):
      if sargs.subcmd == "render"
        for o in outcomes
          console.print(o.report_md)
        end
      else
        summary = Json.Object({
          "ok": Json.Boolean(ok?),
          "states_explored": Json.int(states),
          "transitions_explored": Json.int(transitions),
          "replay": Json.String(replay_msg),
          "tla": tla_msgs.to_json,
          "charts": Json.Array(
            outcomes.map(fn(o)
              Json.Object({
                "title": Json.String(o.title),
                "truncated": Json.Boolean(o.truncated?),
                "violations": Json.int(o.violations),
                "in_sync": Json.Boolean(o.in_sync?),
                "sync_detail": Json.String(o.sync_detail),
                "broken_caught": Json.Boolean(o.broken_caught?)
              })
            end)
          )
        })
        console.print(summary.to_text)
      end
      if ok?: 0 else: 1
  end
end

## Runs statechart verification as a phase inside `arvo verify --tier full`.
fn run_statechart_phase(tier: Text, files: Files, cmd: Command, clock: Clock, env: Env) : Dossier.VerifyEvent
  t = clock.now
  out_dir = ".arvo/dossier/statecharts"
  case evaluate_and_write(out_dir, files, cmd, env, None)
    Error(err):
      var ev = Dossier.new_event(t.to_text, tier, "statechart", "fail", elapsed_ms(clock, t))
      ev.detail = Some(err)
      ev
    Ok((ok?, states, transitions, outcomes, replay_msg, _tla)):
      var ev = Dossier.new_event(
        t.to_text,
        tier,
        "statechart",
        if ok?: "pass" else: "fail",
        elapsed_ms(clock, t)
      )
      sync_notes = outcomes.map(fn(o) "#{o.slug}=#{o.sync_detail}" end).join(", ")
      ev.total = Some(states)
      ev.passed = Some(if ok?: outcomes.size else: 0)
      ev.failed = Some(if ok?: 0 else: 1)
      ev.detail = Some(
        "#{outcomes.size} charts, #{states} states, #{transitions} transitions, #{replay_msg} (#{sync_notes})"
      )
      ev
  end
end

test "StatechartCmd explores charts, verifies sync commits and broken variants, and runs TLA hooks"
  dt = default_timeouts()
  assert dt.git_secs == 15 and dt.mo_secs == 60 and dt.tlc_secs == 120

  assert parse_statechart_args([]) ==
    Ok(StatechartArgs(subcmd: "check", out_dir: None, tla_file: None, help?: false))
  assert parse_statechart_args(["--help"]) is Ok(h1) and h1.help?
  assert parse_statechart_args(["render", "-h"]) is Ok(h2) and h2.help?
  assert parse_statechart_args(["--tla", "specs/x.tla", "--out", ".arvo/out", "render"]) ==
    Ok(
      StatechartArgs(
        subcmd: "render",
        out_dir: Some(".arvo/out"),
        tla_file: Some("specs/x.tla"),
        help?: false
      )
    )
  for bad in [["--out"], ["--tla"], ["--out", "-x"], ["bogus"], ["check", "render"]]
    assert parse_statechart_args(bad) is Error(_)
  end
  assert extract_covered_file_paths(["a.mo:f1,f2", "a.mo:f3", ":skip", "b.mo"]) == ["a.mo", "b.mo"]

  t0 = Time.parse("2026-11-25T22:10:00Z") or stop "t0"
  assert elapsed_ms(Clock.fixed(t0 - 2.milliseconds), t0) == 0
  assert elapsed_ms(Clock.fixed(t0), t0) == 0
  assert elapsed_ms(Clock.fixed(t0 + 1.millisecond), t0) == 1
  assert elapsed_ms(Clock.fixed(t0 + 5.milliseconds), t0) == 5

  replay_ok_json = "{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":0,\"errors\":0}\n"
  replay_fail_json = "{\"record\":\"totals\",\"passed\":0,\"failed\":1,\"stopped\":0,\"errors\":0}\n"
  rep_clean = Command.replies([
    (
      Command.spec(
        "git",
        ["diff", "--name-only", "623f404124b5bf27f13a595a0dc174a997f49dee", "--", "lib/arvo/jobs.mo"]
      ),
      Command.ok_output("\n")
    ),
    (
      Command.spec(
        "git",
        ["diff", "--name-only", "4ea7e818b88a38fe86021a500fd866e0aa392557", "--", "lib/arvo/session.mo"]
      ),
      Command.ok_output("\n")
    ),
    (
      Command.spec("mo", ["test", "--json", "lib/arvo/statechart.mo"]),
      Command.ok_output(replay_ok_json)
    ),
    (Command.spec("tlc", ["-cleanup", "specs/formal/jobs.tla"]), Command.ok_output("Model checking completed.\n")),
    (Command.spec("tlc", ["-cleanup", "specs/formal/bad.tla"]), Command.output(1, "", "Invariant violated"))
  ])

  c_help = Console.fake()
  assert run_statechart_cmd(
    StatechartArgs(subcmd: "check", out_dir: None, tla_file: None, help?: true),
    Files.in_memory({}),
    Command.fake(rep_clean),
    Env.of({}),
    c_help
  ) ==
    0
  assert c_help.printed.any?(fn(l) l.contains?("arvo statechart") end)

  files_ok = Files.in_memory({})
  c_chk = Console.fake()
  assert run_statechart_cmd(
    StatechartArgs(subcmd: "check", out_dir: None, tla_file: None, help?: false),
    files_ok,
    Command.fake(rep_clean),
    Env.of({}),
    c_chk
  ) ==
    0
  assert (c_chk.printed.first or "").contains?("\"states_explored\":15")
  assert (c_chk.printed.first or "").contains?("\"transitions_explored\":20")
  assert files_ok.exists?(".arvo/dossier/statecharts/jobs.mmd")
  assert files_ok.exists?(".arvo/dossier/statecharts/session.mmd")
  assert (c_chk.printed.first or "").split("\"broken_caught\":true").size == 3
  assert files_ok.read_text(".arvo/dossier/statecharts/report.json") is Ok(sc_rjson)
  assert sc_rjson.split("\"broken_caught\": true").size == 3
  assert files_ok.read_text(".arvo/dossier/statecharts/report.md") is Ok(sc_rmd)
  assert sc_rmd.ends_with?("- Replay check: replay passed (1 check(s))\n")

  c_ren = Console.fake()
  assert run_statechart_cmd(
    StatechartArgs(subcmd: "render", out_dir: Some(".arvo/custom"), tla_file: None, help?: false),
    files_ok,
    Command.fake(rep_clean),
    Env.of({}),
    c_ren
  ) ==
    0
  assert c_ren.printed.any?(fn(l) l.contains?("stateDiagram-v2") end)

  ev_pass = run_statechart_phase("full", files_ok, Command.fake(rep_clean), Clock.fixed(t0), Env.of({}))
  assert ev_pass.status == "pass" and ev_pass.total == Some(15) and ev_pass.passed == Some(2) and
    ev_pass.failed ==
    Some(0)

  # Stale sync_commit detection via git diff AND via ARVO_GIT_DIFF_FILES worktree fallback
  rep_stale_git = Command.replies([
    (
      Command.spec(
        "git",
        ["diff", "--name-only", "623f404124b5bf27f13a595a0dc174a997f49dee", "--", "lib/arvo/jobs.mo"]
      ),
      Command.ok_output("lib/arvo/jobs.mo\n")
    ),
    (
      Command.spec(
        "git",
        ["diff", "--name-only", "4ea7e818b88a38fe86021a500fd866e0aa392557", "--", "lib/arvo/session.mo"]
      ),
      Command.ok_output("")
    ),
    (
      Command.spec("mo", ["test", "--json", "lib/arvo/statechart.mo"]),
      Command.ok_output(replay_ok_json)
    )
  ])
  ev_stale = run_statechart_phase("full", files_ok, Command.fake(rep_stale_git), Clock.fixed(t0), Env.of({}))
  assert ev_stale.status == "fail" and ev_stale.passed == Some(0) and ev_stale.failed == Some(1)
  assert (ev_stale.detail or "").contains?("STALE_FORMAL_CHECK")

  (empty_sync?, _) = check_sync_commit([], "1234567890", Command.fake(rep_clean), Env.of({}))
  assert empty_sync?
  (git_err_ok?, git_err_msg) = check_sync_commit(
    ["lib/arvo/jobs.mo:claim_next"],
    "f11ca6ffc25128538844c952cb0b3bf4cafee177",
    Command.fake(Command.replies([])).allow_programs([]),
    Env.of({"ARVO_GIT_DIFF_FILES": "other.mo,lib/arvo/jobs.mo"})
  )
  assert not git_err_ok? and git_err_msg.contains?("STALE_FORMAL_CHECK")

  (wt_clean?, wt_msg) = check_sync_commit(
    ["lib/arvo/jobs.mo"],
    "f11ca6ffc25128538844c952cb0b3bf4cafee177",
    Command.fake(
      Command.replies([
        (
          Command.spec("git", ["diff", "--name-only", "f11ca6ffc25128538844c952cb0b3bf4cafee177", "--", "lib/arvo/jobs.mo"]),
          Command.output(128, "", "not a git repository")
        )
      ])
    ),
    Env.of({})
  )
  assert not wt_clean? and wt_msg.contains?("STALE_FORMAL_CHECK")

  # Replay failure, blocked filesystem, and TLA+ discovered + failing/missing TLC branches
  rep_replay_fail = Command.replies([
    (
      Command.spec("mo", ["test", "--json", "lib/arvo/statechart.mo"]),
      Command.ok_output(replay_fail_json)
    )
  ])
  assert run_statechart_cmd(
    StatechartArgs(subcmd: "check", out_dir: None, tla_file: None, help?: false),
    files_ok,
    Command.fake(rep_replay_fail),
    Env.of({}),
    Console.fake()
  ) ==
    1
  assert run_statechart_cmd(
    StatechartArgs(subcmd: "check", out_dir: None, tla_file: None, help?: false),
    Files.in_memory({".arvo": "blocker"}),
    Command.fake(rep_clean),
    Env.of({}),
    Console.fake()
  ) ==
    1
  assert run_statechart_phase(
    "full",
    Files.in_memory({".arvo": "blocker"}),
    Command.fake(rep_clean),
    Clock.fixed(t0),
    Env.of({})
  ).status ==
    "fail"

  files_tla = Files.in_memory({
    "specs/formal/jobs.tla": "---- MODULE jobs ----\n====",
    "specs/formal/README.md": "# notes\n",
    "specs/formal/sub.tla/inside.txt": "not a spec"
  })
  assert find_tla_files(files_tla.read_only, None) == ["specs/formal/jobs.tla"]
  assert run_statechart_cmd(
    StatechartArgs(subcmd: "check", out_dir: None, tla_file: None, help?: false),
    files_tla,
    Command.fake(rep_clean),
    Env.of({}),
    Console.fake()
  ) ==
    0
  assert run_statechart_cmd(
    StatechartArgs(subcmd: "check", out_dir: None, tla_file: Some("specs/formal/bad.tla"), help?: false),
    files_tla,
    Command.fake(rep_clean),
    Env.of({}),
    Console.fake()
  ) ==
    1
  assert run_statechart_cmd(
    StatechartArgs(subcmd: "check", out_dir: None, tla_file: Some("specs/formal/missing_tlc.tla"), help?: false),
    files_tla,
    Command.fake(rep_clean).allow_programs(["git", "mo"]),
    Env.of({}),
    Console.fake()
  ) ==
    1
  assert run_replay_suite(Command.fake(rep_clean).allow_programs([])).0 == false
  for (bad_rep, expect_sub) in [
    (Command.output(1, replay_ok_json, ""), "failed=0"),
    (
      Command.ok_output("{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":1,\"errors\":0}\n"),
      "failed=1"
    ),
    (
      Command.ok_output("{\"record\":\"totals\",\"passed\":1,\"failed\":0,\"stopped\":0,\"errors\":1}\n"),
      "errors=1"
    ),
    (
      Command.ok_output("{\"record\":\"totals\",\"passed\":0,\"failed\":0,\"stopped\":0,\"errors\":0}\n"),
      "passed=0"
    )
  ]
    r_bad = Command.replies([(Command.spec("mo", ["test", "--json", "lib/arvo/statechart.mo"]), bad_rep)])
    (rok?, rmsg) = run_replay_suite(Command.fake(r_bad))
    assert not rok? and rmsg.contains?(expect_sub)
  end
end
