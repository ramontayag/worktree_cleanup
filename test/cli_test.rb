# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "json"
require "open3"
require "tmpdir"
require_relative "../lib/worktree_cleanup"

# The contract of the worktree-cleanup executable.
#
# The script removes linked worktrees whose work is already merged into
# the base branch. These tests run the real executable against a real
# temporary repository, so the git commands, the worktree bookkeeping and
# the report all have to hold up. The `gh` binary is stubbed on PATH.
class CleanWorktreesTest < Minitest::Test
  def repo_root
    @repo_root ||= File.expand_path("..", __dir__)
  end

  def bin_clean
    @bin_clean ||= ENV.fetch("WORKTREE_CLEANUP_EXECUTABLE", File.join(repo_root, "exe/worktree-cleanup"))
  end

  def setup
    @tmpdir = Dir.mktmpdir("clean_worktrees_test")
    @remote = File.join(@tmpdir, "remote.git")
    @repo = File.join(@tmpdir, "repo")
    @stub_bin = File.join(@tmpdir, "bin")
    @gh_stub = File.join(@tmpdir, "gh.json")
    @gh_open_stub = File.join(@tmpdir, "gh-open.json")

    FileUtils.mkdir_p(@stub_bin)
    create_remote
    create_repository
    install_gh_stub([ { headRefName: "nothing", number: 1, state: "CLOSED", baseRefName: "main" } ])
  end

  def teardown
    FileUtils.rm_rf(@tmpdir)
  end

  # ---- Reporting ----

  def test_symbolic_remote_head_preserves_its_linked_base_checkout
    run_git(@repo, "switch", "-c", "primary")
    run_git(@repo, "symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main")
    path = worktree_path("linked-main")
    run_git(@repo, "worktree", "add", path, "main")

    output, status = run_script("--base", "origin/HEAD", "--apply")

    assert status.success?, output
    assert File.directory?(path)
    assert branch_exists?("main")
  end

  def test_paths_with_unicode_tabs_and_newlines_can_be_removed
    name = "café\tproject\nfinished"
    create_worktree(name, branch: "feature/special-path")
    commit_in_worktree(name, "a.txt", "merged work")
    merge_into_main("feature/special-path")
    push_main

    output, status = run_script("--apply")

    assert status.success?, output
    refute File.exist?(worktree_path(name))
    refute branch_exists?("feature/special-path")
  end

  def test_index_flags_that_hide_edits_preserve_the_worktree
    %w[assume-unchanged skip-worktree].each do |flag|
      create_worktree(flag, branch: "feature/#{flag}")
      commit_in_worktree(flag, "a.txt", "merged #{flag} work")
      merge_into_main("feature/#{flag}")
      push_main
      path = worktree_path(flag)
      run_git(path, "update-index", "--#{flag}", "a.txt")
      File.write(File.join(path, "a.txt"), "hidden local edits")

      output, status = run_script("--apply")

      assert status.success?, output
      assert_equal "hidden local edits", File.read(File.join(path, "a.txt"))
      assert branch_exists?("feature/#{flag}")
    end
  end

  def test_symbolic_merge_identifiers_do_not_prove_a_pull_request_merge
    create_worktree("symbolic-merge", branch: "feature/symbolic-merge")
    commit_in_worktree("symbolic-merge", "a.txt", "unfinished work")
    head = run_git(worktree_path("symbolic-merge"), "rev-parse", "HEAD").strip
    install_gh_stub([ { headRefName: "feature/symbolic-merge", number: 7,
      state: "MERGED", baseRefName: "main", headRefOid: head, mergeCommit: { oid: "HEAD" } } ])

    output, status = run_script("--apply")

    assert status.success?, output
    assert File.directory?(worktree_path("symbolic-merge"))
    assert branch_exists?("feature/symbolic-merge")
  end

  # A branch whose commits reached the base branch is ready to remove.
  def test_reports_a_merged_worktree_as_ready_to_remove
    create_worktree("merged", branch: "feature/merged")
    commit_in_worktree("merged", "a.txt", "merged work")
    merge_into_main("feature/merged")
    push_main

    output, status = run_script

    assert status.success?, output
    assert_includes output, "Ready to remove (1)"
    assert_includes output, "feature/merged"
  end

  # A worktree with uncommitted changes keeps work that is not on any
  # branch, so it is never removed.
  def test_keeps_a_worktree_with_uncommitted_changes
    create_worktree("dirty", branch: "feature/dirty")
    commit_in_worktree("dirty", "a.txt", "work")
    merge_into_main("feature/dirty")
    push_main
    File.write(File.join(worktree_path("dirty"), "a.txt"), "uncommitted change")

    output, status = run_script

    assert status.success?, output
    assert_includes output, "has uncommitted changes"
    refute_includes output, "Ready to remove (1)"
  end

  # An untracked file is uncommitted work too.
  def test_keeps_a_worktree_with_an_untracked_file
    create_worktree("untracked", branch: "feature/untracked")
    commit_in_worktree("untracked", "a.txt", "work")
    merge_into_main("feature/untracked")
    push_main
    File.write(File.join(worktree_path("untracked"), "scratch.txt"), "notes")

    output, status = run_script

    assert status.success?, output
    assert_includes output, "has uncommitted changes"
  end

  # An open pull request means the work is still in review.
  def test_keeps_a_worktree_whose_pull_request_is_open
    create_worktree("open", branch: "feature/open")
    commit_in_worktree("open", "a.txt", "work")
    install_gh_stub([ { headRefName: "feature/open", number: 42, state: "OPEN", baseRefName: "main" } ])

    output, status = run_script

    assert status.success?, output
    assert_includes output, "pull request #42 is open"
    refute_includes output, "Ready to remove (1)"
  end

  # A squash merge rewrites the commit, so ancestry cannot see it. The
  # merged pull request is the proof that lets the worktree go.
  def test_removes_a_worktree_proven_merged_by_its_pull_request
    create_worktree("squashed", branch: "feature/squashed")
    commit_in_worktree("squashed", "a.txt", "work")
    pull_request = squash_into_main("squashed", "feature/squashed")
    install_gh_stub([ pull_request ])

    output, status = run_script

    assert status.success?, output
    assert_includes output, "Ready to remove (1)"
    assert_includes output, "feature/squashed"

    output, status = run_script("--apply")
    assert status.success?, output
    refute File.exist?(worktree_path("squashed"))
    refute branch_exists?("feature/squashed")
  end

  # A pull request that merged into another branch proves nothing about
  # the base branch.
  def test_keeps_a_worktree_whose_pull_request_merged_into_another_branch
    create_worktree("other-base", branch: "feature/other-base")
    commit_in_worktree("other-base", "a.txt", "work")
    pull_request = squash_into_main("other-base", "feature/other-base")
    install_gh_stub([ pull_request.merge(baseRefName: "release") ])

    output, status = run_script("--apply")

    assert status.success?, output
    assert_includes output, "not merged into origin/main"
    refute_includes output, "Ready to remove (1)"
    assert File.directory?(worktree_path("other-base"))
    assert branch_exists?("feature/other-base")
  end

  # A pull request that closed without merging leaves the work unmerged.
  def test_keeps_a_worktree_whose_pull_request_closed_without_merging
    create_worktree("closed", branch: "feature/closed")
    commit_in_worktree("closed", "a.txt", "work")
    install_gh_stub([ { headRefName: "feature/closed", number: 9, state: "CLOSED", baseRefName: "main" } ])

    output, status = run_script

    assert status.success?, output
    assert_includes output, "pull request #9 closed without merging"
  end

  # When the pull requests cannot be read, the script cannot prove a
  # squash merge, so it keeps the worktree and says why.
  def test_keeps_a_worktree_when_the_pull_request_state_cannot_be_read
    create_worktree("unknown", branch: "feature/unknown")
    commit_in_worktree("unknown", "a.txt", "work")
    install_failing_gh_stub

    output, status = run_script

    assert status.success?, output
    assert_includes output, "pull request state unknown"
    refute_includes output, "Ready to remove (1)"
  end

  # The main checkout holds the branch the base ref points at.
  def test_never_reports_the_main_checkout
    output, status = run_script

    assert status.success?, output
    refute_includes output, "Ready to remove"
  end

  # A detached worktree has no branch to delete and no name to match a
  # pull request against.
  def test_keeps_a_detached_worktree
    path = File.join(@repo, ".worktrees", "detached")
    run_git(@repo, "worktree", "add", "--detach", path, "main")

    output, status = run_script

    assert status.success?, output
    assert_includes output, "detached HEAD"
    refute_includes output, "Ready to remove (1)"
  end

  # The worktree the caller is standing in holds the caller's own
  # working directory, so it stays.
  def test_keeps_the_worktree_that_holds_the_current_directory
    create_worktree("standing", branch: "feature/standing")
    commit_in_worktree("standing", "a.txt", "work")
    merge_into_main("feature/standing")
    push_main

    output, status = run_script(chdir: worktree_path("standing"))

    assert status.success?, output
    assert_includes output, "holds the current working directory"
    refute_includes output, "Ready to remove (1)"
  end

  # ---- Applying ----

  # The default run reports and changes nothing.
  def test_dry_run_removes_nothing
    create_worktree("dry", branch: "feature/dry")
    commit_in_worktree("dry", "a.txt", "work")
    merge_into_main("feature/dry")
    push_main

    output, status = run_script

    assert status.success?, output
    assert_includes output, "Dry run"
    assert File.directory?(worktree_path("dry")), "the worktree must still be there"
    assert_includes worktree_list, "feature/dry"
  end

  # Applying removes the worktree and the local branch it held.
  def test_apply_removes_the_worktree_and_its_local_branch
    create_worktree("applied", branch: "feature/applied")
    commit_in_worktree("applied", "a.txt", "work")
    merge_into_main("feature/applied")
    push_main

    output, status = run_script("--apply")

    assert status.success?, output
    refute File.exist?(worktree_path("applied")), "the worktree directory must be gone"
    refute_includes worktree_list, "feature/applied"
    refute branch_exists?("feature/applied"), "the local branch must be gone"
  end

  # The summary says how many branches it deleted, so the count has to
  # match what it did.
  def test_apply_reports_how_many_local_branches_it_deleted
    create_worktree("counted", branch: "feature/counted")
    commit_in_worktree("counted", "a.txt", "work")
    merge_into_main("feature/counted")
    push_main

    output, status = run_script("--apply")

    assert status.success?, output
    assert_includes output, "Removed 1 worktrees and 1 local branches."
  end

  # The summary says how many branches it left alone when the caller
  # keeps them.
  def test_apply_reports_no_deleted_branches_when_the_caller_keeps_them
    create_worktree("kept-count", branch: "feature/kept-count")
    commit_in_worktree("kept-count", "a.txt", "work")
    merge_into_main("feature/kept-count")
    push_main

    output, status = run_script("--apply", "--keep-branches")

    assert status.success?, output
    assert_includes output, "Removed 1 worktrees and 0 local branches."
  end

  # The local branch can be kept when the caller wants it.
  def test_apply_keeps_the_local_branch_when_asked
    create_worktree("kept", branch: "feature/kept")
    commit_in_worktree("kept", "a.txt", "work")
    merge_into_main("feature/kept")
    push_main

    output, status = run_script("--apply", "--keep-branches")

    assert status.success?, output
    refute File.exist?(worktree_path("kept")), "the worktree directory must be gone"
    assert branch_exists?("feature/kept"), "the local branch must stay"
  end

  # A worktree nested inside another worktree is removed first, because
  # git refuses to remove a directory that still holds a registered
  # worktree.
  def test_removes_a_nested_worktree_before_the_worktree_that_holds_it
    outer = create_worktree("outer", branch: "feature/outer")
    commit_in_worktree("outer", "a.txt", "work")
    merge_into_main("feature/outer")
    push_main

    inner_path = File.join(outer, ".worktrees", "inner")
    run_git(@repo, "worktree", "add", "-b", "feature/inner", inner_path, "main")
    commit_at(inner_path, "b.txt", "work")
    merge_into_main("feature/inner")
    push_main

    output, status = run_script("--apply")

    assert status.success?, output
    refute File.exist?(inner_path), "the nested worktree must be gone"
    refute File.exist?(outer), "the holding worktree must be gone"
  end

  # The base ref decides what counts as merged.
  def test_the_base_ref_decides_what_counts_as_merged
    run_git(@repo, "update-ref", "refs/remotes/origin/release", "HEAD")
    create_worktree("base", branch: "feature/base")
    commit_in_worktree("base", "a.txt", "work")
    merge_into_main("feature/base")
    push_main

    output, status = run_script("--base", "origin/release")

    assert status.success?, output
    assert_includes output, "not merged into origin/release"
    refute_includes output, "Ready to remove (1)"
  end

  # ---- Arguments ----

  def test_help_prints_usage_and_exits_zero
    output, status = run_script("--help")

    assert status.success?, output
    assert_includes output, "Usage: worktree-cleanup"
  end

  def test_unknown_option_fails_before_inspecting_the_repository
    output, status = run_script("--bogus")

    refute status.success?, "an unknown option must exit non-zero"
    assert_includes output, "invalid option"
  end

  def test_unknown_pull_request_state_keeps_even_a_locally_merged_worktree
    create_worktree("unknown-merged", branch: "feature/unknown-merged")
    commit_in_worktree("unknown-merged", "a.txt", "work")
    merge_into_main("feature/unknown-merged")
    push_main
    install_failing_gh_stub

    output, status = run_script("--apply")

    assert status.success?, output
    assert_includes output, "pull request state unknown"
    assert File.directory?(worktree_path("unknown-merged"))
    assert branch_exists?("feature/unknown-merged")
  end

  def test_new_commits_after_a_squash_merge_are_kept
    create_worktree("reused", branch: "feature/reused")
    commit_in_worktree("reused", "a.txt", "merged work")
    pull_request = squash_into_main("reused", "feature/reused")
    commit_in_worktree("reused", "new.txt", "unfinished work")
    install_gh_stub([ pull_request ])

    output, status = run_script("--apply")

    assert status.success?, output
    assert File.file?(File.join(worktree_path("reused"), "new.txt"))
    assert branch_exists?("feature/reused")
  end

  def test_a_merged_pull_request_cannot_prove_a_merge_missing_from_the_base_ref
    create_worktree("not-in-base", branch: "feature/not-in-base")
    commit_in_worktree("not-in-base", "a.txt", "work")
    head = run_git(worktree_path("not-in-base"), "rev-parse", "HEAD").strip
    install_gh_stub([ { headRefName: "feature/not-in-base", number: 7, state: "MERGED",
      baseRefName: "main", headRefOid: head, mergeCommit: { oid: head } } ])

    output, status = run_script("--apply")

    assert status.success?, output
    assert File.directory?(worktree_path("not-in-base"))
    assert branch_exists?("feature/not-in-base")
  end

  def test_an_older_open_pull_request_keeps_a_branch_with_a_newer_closed_request
    create_worktree("older-open", branch: "feature/older-open")
    commit_in_worktree("older-open", "a.txt", "work")
    merge_into_main("feature/older-open")
    push_main
    install_gh_stub([
      { headRefName: "feature/older-open", number: 1, state: "OPEN", baseRefName: "main" },
      { headRefName: "feature/older-open", number: 2, state: "CLOSED", baseRefName: "main" }
    ])

    output, status = run_script("--apply")

    assert status.success?, output
    assert_includes output, "pull request #1 is open"
    assert File.directory?(worktree_path("older-open"))
  end

  def test_the_base_branch_checkout_is_kept_even_when_it_is_not_the_primary_checkout
    run_git(@repo, "branch", "release")
    path = worktree_path("release")
    run_git(@repo, "worktree", "add", path, "release")

    output, status = run_script("--base", "release", "--apply")

    assert status.success?, output
    assert File.directory?(path)
    assert branch_exists?("release")
  end

  def test_a_missing_base_ref_fails_without_removing_worktrees
    create_worktree("missing-base", branch: "feature/missing-base")
    commit_in_worktree("missing-base", "a.txt", "work")
    install_gh_stub([ { headRefName: "feature/missing-base", number: 7, state: "MERGED", baseRefName: "missing" } ])

    output, status = run_script("--base", "origin/missing", "--apply")

    assert_equal 2, status.exitstatus, output
    assert_includes output, "base ref"
    assert File.directory?(worktree_path("missing-base"))
  end

  def test_staged_changes_are_kept_on_apply
    create_worktree("staged", branch: "feature/staged")
    commit_in_worktree("staged", "a.txt", "work")
    merge_into_main("feature/staged")
    push_main
    File.write(File.join(worktree_path("staged"), "a.txt"), "staged work")
    run_git(worktree_path("staged"), "add", "a.txt")

    output, status = run_script("--apply")

    assert status.success?, output
    assert_equal "staged work", File.read(File.join(worktree_path("staged"), "a.txt"))
  end

  def test_ignored_files_are_kept_on_apply
    create_worktree("ignored", branch: "feature/ignored")
    commit_in_worktree("ignored", ".gitignore", ".env")
    merge_into_main("feature/ignored")
    push_main
    notes = File.join(worktree_path("ignored"), ".env")
    File.write(notes, "local configuration")

    output, status = run_script("--apply")

    assert status.success?, output
    assert_equal "local configuration", File.read(notes)
    assert branch_exists?("feature/ignored")
  end

  def test_locked_worktree_removal_reports_failure_and_preserves_its_branch
    create_worktree("locked", branch: "feature/locked")
    commit_in_worktree("locked", "a.txt", "work")
    merge_into_main("feature/locked")
    push_main
    run_git(@repo, "worktree", "lock", worktree_path("locked"))

    output, status = run_script("--apply")

    assert_equal 1, status.exitstatus, output
    assert File.directory?(worktree_path("locked"))
    assert branch_exists?("feature/locked")
  end

  def test_a_non_repository_reports_a_setup_error
    output, status = run_script("--repo", @tmpdir)

    assert_equal 2, status.exitstatus, output
    assert_includes output, "worktree-cleanup:"
  end

  def test_unexpected_positional_arguments_are_rejected
    output, status = run_script("unexpected")

    assert_equal 2, status.exitstatus, output
    assert_includes output, "unexpected"
  end

  def test_version_does_not_need_a_repository
    output, status = run_script("--repo", @tmpdir, "--version")

    assert status.success?, output
    assert_match(/\Aworktree-cleanup \d+\.\d+\.\d+\s*\z/, output)
  end

  def test_new_commits_after_a_report_prevent_apply_from_removing_the_worktree
    create_worktree("changed-tip", branch: "feature/changed-tip")
    commit_in_worktree("changed-tip", "a.txt", "merged work")
    merge_into_main("feature/changed-tip")
    push_main
    cleanup = cleanup_service
    report = cleanup.report
    assert_equal 1, report.ready.length
    commit_in_worktree("changed-tip", "new.txt", "new work")

    result = cleanup.apply(report)

    assert_equal 0, result.removed_count
    assert_equal 1, result.failure_count
    assert File.file?(File.join(worktree_path("changed-tip"), "new.txt"))
    assert branch_exists?("feature/changed-tip")
  end

  def test_new_untracked_files_after_a_report_are_kept
    create_worktree("changed-files", branch: "feature/changed-files")
    commit_in_worktree("changed-files", "a.txt", "merged work")
    merge_into_main("feature/changed-files")
    push_main
    cleanup = cleanup_service
    report = cleanup.report
    assert_equal 1, report.ready.length
    notes = File.join(worktree_path("changed-files"), "notes.txt")
    File.write(notes, "new notes")

    result = cleanup.apply(report)

    assert_equal 0, result.removed_count
    assert_equal 1, result.failure_count
    assert_equal "new notes", File.read(notes)
  end

  def test_malformed_pull_request_records_keep_locally_merged_worktrees
    create_worktree("malformed", branch: "feature/malformed")
    commit_in_worktree("malformed", "a.txt", "work")
    merge_into_main("feature/malformed")
    push_main
    install_gh_stub([ nil ])

    output, status = run_script("--apply")

    assert status.success?, output
    assert_includes output, "pull request state unknown"
    assert File.directory?(worktree_path("malformed"))
  end

  def test_reaching_the_open_pull_request_limit_keeps_worktrees
    create_worktree("limited", branch: "feature/limited")
    commit_in_worktree("limited", "a.txt", "work")
    merge_into_main("feature/limited")
    push_main
    install_gh_stub(Array.new(500) { |index|
      { headRefName: "other-#{index}", number: index + 1, state: "OPEN", baseRefName: "main" }
    })

    output, status = run_script("--apply")

    assert status.success?, output
    assert_includes output, "pull request state unknown"
    assert File.directory?(worktree_path("limited"))
  end

  def test_a_separate_open_request_query_finds_requests_missing_from_recent_history
    create_worktree("old-open", branch: "feature/old-open")
    commit_in_worktree("old-open", "a.txt", "work")
    merge_into_main("feature/old-open")
    push_main
    install_gh_stub(
      [ { headRefName: "other", number: 999, state: "CLOSED", baseRefName: "main" } ],
      open_pull_requests: [ { headRefName: "feature/old-open", number: 1, state: "OPEN", baseRefName: "main" } ]
    )

    output, status = run_script("--apply")

    assert status.success?, output
    assert_includes output, "pull request #1 is open"
    assert File.directory?(worktree_path("old-open"))
    assert branch_exists?("feature/old-open")
  end

  def test_an_unmerged_nested_worktree_and_its_files_survive_apply
    outer = create_worktree("kept-outer", branch: "feature/kept-outer")
    commit_in_worktree("kept-outer", "a.txt", "merged work")
    merge_into_main("feature/kept-outer")
    push_main
    inner = File.join(outer, ".worktrees", "unfinished")
    run_git(@repo, "worktree", "add", "-b", "feature/unfinished", inner, "main")
    commit_at(inner, "notes.txt", "unfinished work")

    _output, status = run_script("--apply")

    assert_equal 1, status.exitstatus
    assert_equal "unfinished work\n", File.read(File.join(inner, "notes.txt"))
    assert branch_exists?("feature/unfinished")
    assert branch_exists?("feature/kept-outer")
  end

  def test_untracked_files_beside_a_nested_worktree_survive_apply
    outer = create_worktree("notes-outer", branch: "feature/notes-outer")
    commit_in_worktree("notes-outer", "a.txt", "merged work")
    merge_into_main("feature/notes-outer")
    push_main
    inner = File.join(outer, ".worktrees", "finished")
    run_git(@repo, "worktree", "add", "-b", "feature/finished", inner, "main")
    notes = File.join(outer, ".worktrees", "notes.txt")
    File.write(notes, "keep these notes")

    output, status = run_script("--apply")

    assert status.success?, output
    assert_equal "keep these notes", File.read(notes)
    assert branch_exists?("feature/notes-outer")
    refute File.exist?(inner)
  end

  def test_a_branch_moved_after_worktree_removal_is_not_deleted
    create_worktree("moved-branch", branch: "feature/moved-branch")
    commit_in_worktree("moved-branch", "a.txt", "merged work")
    merge_into_main("feature/moved-branch")
    push_main
    tree = run_git(@repo, "rev-parse", "HEAD^{tree}").strip
    new_tip = run_git(@repo, "commit-tree", tree, "-p", "HEAD", "-m", "new work").strip
    repo = @repo
    client = WorktreeCleanup::GitClient.new(directory: repo)
    client.define_singleton_method(:remove_worktree) do |path|
      result = super(path)
      if result.success?
        _stdout, stderr, status = Open3.capture3("git", "-C", repo, "update-ref", "refs/heads/feature/moved-branch", new_tip)
        raise stderr unless status.success?
      end
      result
    end
    cleanup = cleanup_service(git_client: client)

    result = cleanup.apply(cleanup.report)

    assert_equal 1, result.removed_count
    assert_equal 1, result.failure_count
    assert_empty result.removed_branches
    assert_equal new_tip, run_git(@repo, "rev-parse", "feature/moved-branch").strip
  end

  private
    def cleanup_service(git_client: WorktreeCleanup::GitClient.new(directory: @repo))
      WorktreeCleanup::Cleanup.new(
        git_client: git_client,
        pull_request_client: Struct.new(:by_branch).new({}),
        base: "origin/main", current_directory: @repo
      )
    end

    def squash_into_main(name, branch)
      head = run_git(worktree_path(name), "rev-parse", "HEAD").strip
      run_git(@repo, "merge", "--squash", branch)
      run_git(@repo, "commit", "-m", "squash #{branch}")
      push_main
      { headRefName: branch, number: 7, state: "MERGED", baseRefName: "main",
        headRefOid: head, mergeCommit: { oid: run_git(@repo, "rev-parse", "HEAD").strip } }
    end

    # Runs the script against the temporary repository.
    #
    # The `gh` stub on PATH answers every pull request query with the
    # fixture file. Returns [combined_output, status].
    def run_script(*arguments, chdir: nil)
      Open3.capture2e(
        { "PATH" => "#{@stub_bin}:#{ENV.fetch("PATH")}", "GH_STUB_FILE" => @gh_stub, "GH_STUB_OPEN_FILE" => @gh_open_stub },
        bin_clean,
        "--repo", @repo,
        *arguments,
        chdir: chdir || @repo
      )
    end

    # The path of a worktree inside the temporary repository.
    def worktree_path(name)
      File.join(@repo, ".worktrees", name)
    end

    def create_remote
      run_git(@tmpdir, "init", "--bare", "--initial-branch=main", @remote)
    end

    def create_repository
      run_git(@tmpdir, "clone", @remote, @repo)
      run_git(@repo, "config", "user.email", "clean-worktrees@example.com")
      run_git(@repo, "config", "user.name", "Clean Worktrees Test")
      File.write(File.join(@repo, "README.md"), "seed\n")
      run_git(@repo, "add", "README.md")
      run_git(@repo, "commit", "-m", "seed")
      run_git(@repo, "push", "origin", "main")
    end

    # Adds a worktree on a new branch.
    def create_worktree(name, branch:)
      path = worktree_path(name)
      FileUtils.mkdir_p(File.dirname(path))
      run_git(@repo, "worktree", "add", "-b", branch, path, "main")
      path
    end

    # Commits a file inside a worktree.
    def commit_in_worktree(name, file, message)
      commit_at(worktree_path(name), file, message)
    end

    # Commits a file inside a worktree at an explicit path.
    def commit_at(path, file, message)
      File.write(File.join(path, file), "#{message}\n")
      run_git(path, "add", file)
      run_git(path, "commit", "-m", message)
    end

    # Moves the base branch onto a branch, so the branch's commits
    # become ancestors of it.
    def merge_into_main(branch)
      run_git(@repo, "merge", "--ff-only", branch)
    end

    def push_main
      run_git(@repo, "push", "origin", "main")
    end

    def worktree_list
      stdout, _stderr, _status = Open3.capture3("git", "-C", @repo, "worktree", "list")
      stdout
    end

    def branch_exists?(branch)
      _stdout, _stderr, status = Open3.capture3("git", "-C", @repo, "rev-parse", "--verify", "refs/heads/#{branch}")
      status.success?
    end

    # Installs a `gh` stub that answers with the given pull requests.
    def install_gh_stub(pull_requests, open_pull_requests: pull_requests)
      File.write(@gh_stub, JSON.generate(pull_requests))
      File.write(@gh_open_stub, JSON.generate(open_pull_requests))
      File.write(File.join(@stub_bin, "gh"), <<~SH)
        #!/usr/bin/env sh
        if [ "$4" = open ]; then
          cat "$GH_STUB_OPEN_FILE"
        else
          cat "$GH_STUB_FILE"
        fi
      SH
      File.chmod(0o755, File.join(@stub_bin, "gh"))
    end

    # Installs a `gh` stub that fails, the way an unauthenticated or
    # unreachable forge fails.
    def install_failing_gh_stub
      File.write(File.join(@stub_bin, "gh"), <<~SH)
        #!/usr/bin/env sh
        echo "not authenticated" >&2
        exit 1
      SH
      File.chmod(0o755, File.join(@stub_bin, "gh"))
    end

    # Runs a git command and fails the test when it does not succeed.
    def run_git(directory, *arguments)
      stdout, stderr, status = Open3.capture3("git", "-C", directory, *arguments)
      raise "git #{arguments.join(" ")} failed: #{stderr}#{stdout}" unless status.success?

      stdout
    end
end
