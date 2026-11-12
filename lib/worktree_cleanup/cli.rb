# frozen_string_literal: true

#
# worktree-cleanup — remove linked worktrees whose work is already merged.
#
# A repository accumulates worktrees: one per task, one per branch, one
# per experiment. Once the work lands, the worktree is left behind. This
# script finds the ones that are safe to remove and removes them.
#
# A worktree is removed only when all of these hold:
#
#   1. It is not the main checkout.
#   2. It has a branch checked out.
#   3. Its working tree has no staged, unstaged, or untracked files.
#   4. No pull request for its branch is open.
#   5. Its work is already in the base branch.
#
# The merge is proven by local ancestry. A squash merge rewrites the
# commit, so ancestry cannot see it; a merged pull request that targeted
# the base branch is the remaining proof. Anything that cannot be proven
# keeps the worktree.
#
# The script reports what it would do and changes nothing. Pass --apply to
# remove the worktrees. It never deletes a branch on the remote and never
# touches a remote-tracking ref.
#
# Usage:
#   worktree-cleanup [--apply] [--base REF] [--repo PATH] [--keep-branches]

require "optparse"
require "open3"

require_relative "cleanup"

class WorktreeCleanup::CLI
  DEFAULT_BASE = "origin/main"

  def initialize(argv, stdout: $stdout, stderr: $stderr)
    @argv = argv
    @stdout = stdout
    @stderr = stderr
    @options = { apply: false, base: DEFAULT_BASE, repo: nil, keep_branches: false }
  end

  def run
    return usage if @argv.include?("--help") || @argv.include?("-h")
    if @argv.include?("--version")
      @stdout.puts "worktree-cleanup #{WorktreeCleanup::VERSION}"
      return 0
    end

    parse!
    cleanup = build_cleanup
    report = cleanup.report

    print_report(report)

    unless @options[:apply]
      @stdout.puts
      @stdout.puts "Dry run. Nothing was removed. Run again with --apply to remove these worktrees."
      return 0
    end

    apply(cleanup, report)
  rescue WorktreeCleanup::GitClient::Error, OptionParser::ParseError => error
    @stderr.puts "worktree-cleanup: #{error.message}"
    2
  end

  private
    def parse!
      parser = OptionParser.new do |options|
        options.banner = "Usage: worktree-cleanup [options]"
        options.on("--apply", "Remove the worktrees. Without it, only report.") { @options[:apply] = true }
        options.on("--base REF", "Base branch that must hold the work. Default: #{DEFAULT_BASE}") { |value| @options[:base] = value }
        options.on("--repo PATH", "Repository to inspect. Default: the current repository.") { |value| @options[:repo] = value }
        options.on("--keep-branches", "Remove the worktrees but keep the local branches.") { @options[:keep_branches] = true }
      end
      parser.parse!(@argv)
      raise OptionParser::InvalidArgument, @argv.join(" ") unless @argv.empty?
    end

    def build_cleanup
      directory = @options[:repo] || "."
      WorktreeCleanup::Cleanup.new(
        git_client: WorktreeCleanup::GitClient.new(directory: directory),
        pull_request_client: WorktreeCleanup::PullRequestClient.new(directory: directory),
        base: @options[:base]
      )
    end

    def print_report(report)
      @stdout.puts "Worktree cleanup for #{@options[:repo] || "."}"
      @stdout.puts "Base ref: #{report.base}"
      @stdout.puts

      if report.ready.empty?
        @stdout.puts "Nothing to remove."
      else
        @stdout.puts "Ready to remove (#{report.ready.length}):"
        report.ready.each do |candidate|
          @stdout.puts "  #{display_path(candidate.worktree.path)}  (branch: #{candidate.worktree.branch})"
        end
      end

      @stdout.puts
      print_kept(report.kept)
    end

    # Prints the kept worktrees, grouped by the reason they were kept.
    def print_kept(kept)
      if kept.empty?
        @stdout.puts "Keeping none."
        return
      end

      @stdout.puts "Keeping (#{kept.length}):"
      kept.group_by(&:reason).sort_by { |reason, _candidates| reason }.each do |reason, candidates|
        @stdout.puts "  #{reason} (#{candidates.length}):"
        candidates.each { |candidate| @stdout.puts "    #{display_path(candidate.worktree.path)}" }
      end
    end

    def apply(cleanup, report)
      result = cleanup.apply(report, keep_branches: @options[:keep_branches])

      @stdout.puts
      @stdout.puts "Removed #{result.removed_count} worktrees and #{result.removed_branches.length} local branches."

      result.failures.each do |path, message|
        @stderr.puts "worktree-cleanup: could not clean up #{path}: #{message}"
      end

      result.failure_count.zero? ? 0 : 1
    end

    # Shows the path relative to the repository when it sits inside it.
    def display_path(path)
      root = repository_root
      return path.to_s if root.nil?

      absolute = File.expand_path(path.to_s)
      prefix = "#{File.expand_path(root)}/"
      absolute.start_with?(prefix) ? absolute.delete_prefix(prefix) : absolute
    end

    # The root of the repository being inspected.
    def repository_root
      return @repository_root if defined?(@repository_root)

      @repository_root = begin
        stdout, _stderr, status = Open3.capture3(
          "git", "-C", @options[:repo] || ".", "rev-parse", "--show-toplevel"
        )
        status.success? ? stdout.strip : nil
      rescue Errno::ENOENT
        nil
      end
    end

    def usage
      @stdout.puts "Usage: worktree-cleanup [--apply] [--base REF] [--repo PATH] [--keep-branches]"
      @stdout.puts
      @stdout.puts "Removes linked worktrees whose work is already merged into the base branch."
      @stdout.puts "Without --apply the script only reports."
      @stdout.puts "Use --version to print the installed version."
      0
    end
end
