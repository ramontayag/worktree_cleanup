# frozen_string_literal: true

require_relative "git_client"
require_relative "pull_request_client"

module WorktreeCleanup
  # Decides which linked worktrees can be removed, and removes them.
  #
  # ## Contract
  #
  #   report = WorktreeCleanup::Cleanup.new(base: "origin/main").report
  #
  # The report holds every worktree git knows about, split into the ones
  # that are ready to remove and the ones that are kept. Each kept
  # worktree carries the reason it was kept.
  #
  # ## The rules
  #
  # A worktree is removed only when every one of these holds:
  #
  #   1. It is not the main checkout.
  #   2. It has a branch checked out.
  #   3. Its working tree has no staged, unstaged, or untracked files.
  #   4. No pull request for its branch is open.
  #   5. Its work is already in the base branch.
  #
  # ## How a merge is proven
  #
  # Local ancestry is the first proof. A branch that was merged into the
  # base branch has its commits reachable from the base ref, and that
  # says the work landed.
  #
  # A squash merge rewrites the commit, so ancestry cannot see it. The
  # merged pull request is the remaining proof, and it must have
  # targeted the base branch. A pull request that merged somewhere else
  # proves nothing about the base branch.
  #
  # ## Failing closed
  #
  # Anything the rules cannot prove keeps the worktree. A pull request
  # that cannot be read is not the same as a branch with no pull
  # request, and the two are reported differently.
  class Cleanup
    # One worktree and the decision made about it.
    Candidate = Struct.new(:worktree, :removable, :reason, :head_sha, keyword_init: true) do
      def removable?
        removable == true
      end
    end

    # Every worktree, split into the ones to remove and the ones to keep.
    Report = Struct.new(:ready, :kept, :base, :pull_requests_known, keyword_init: true) do
      def ready?
        !ready.empty?
      end
    end

    # What an apply did.
    Result = Struct.new(:removed, :removed_branches, :failures, keyword_init: true) do
      def removed_count
        removed.length
      end

      def failure_count
        failures.length
      end
    end

    def initialize(git_client: GitClient.new, pull_request_client: PullRequestClient.new, base: "origin/main", current_directory: Dir.pwd)
      @git_client = git_client
      @pull_request_client = pull_request_client
      @base = base
      @current_directory = File.expand_path(current_directory)
    end

    # Classifies every worktree. Nothing is removed.
    def report
      @base_commit = git_client.commit_sha(base)
      raise GitClient::Error, "base ref #{base.inspect} does not name an available commit" unless @base_commit

      @base_branch = git_client.base_branch(base)
      worktrees = git_client.worktrees
      primary = worktrees.first&.path
      pull_requests = pull_request_client.by_branch
      worktree_paths = worktrees.map { |worktree| File.expand_path(worktree.path.to_s) }

      decisions = worktrees.drop(1).map do |worktree|
        classify(worktree, primary, pull_requests, worktree_paths)
      end

      Report.new(
        ready: decisions.select(&:removable?).sort_by { |candidate| candidate.worktree.path.to_s },
        kept: decisions.reject(&:removable?),
        base: base,
        pull_requests_known: !pull_requests.nil?
      )
    end

    # Removes the worktrees a report marked ready.
    #
    # Nested worktrees are removed before the worktrees that hold them,
    # because git refuses to remove a directory that still contains a
    # registered worktree.
    def apply(report, keep_branches: false)
      current = self.report.ready.to_h do |candidate|
        [ [ candidate.worktree.path, candidate.worktree.branch, candidate.head_sha ], candidate ]
      end
      removed = []
      removed_branches = []
      failures = []

      report.ready.sort_by { |candidate| -candidate.worktree.depth }.each do |candidate|
        worktree = candidate.worktree
        unless current.key?([ worktree.path, worktree.branch, candidate.head_sha ])
          failures << [ worktree.path, "worktree state changed; run the report again" ]
          next
        end
        result = git_client.remove_worktree(worktree.path)

        unless result.success?
          failures << [ worktree.path, result.stderr.to_s.strip ]
          next
        end

        removed << worktree.path
        next if keep_branches

        delete_branch(candidate, removed_branches, failures)
      end

      git_client.prune

      Result.new(removed: removed, removed_branches: removed_branches, failures: failures)
    end

    private
      attr_reader :git_client, :pull_request_client, :base

      def classify(worktree, primary, pull_requests, worktree_paths)
        return keep(worktree, "the main checkout") if worktree.path == primary
        return keep(worktree, "detached HEAD") if worktree.detached?
        return keep(worktree, "the base branch checkout") if worktree.branch == @base_branch
        return keep(worktree, "holds the current working directory") if holds_current_directory?(worktree.path)
        return keep(worktree, "has uncommitted changes or ignored files") if dirty?(worktree, worktree_paths)
        return keep(worktree, "pull request state unknown") if pull_requests.nil?

        pull_request = pull_requests[worktree.branch]
        return keep(worktree, "pull request ##{pull_request.number} is open") if pull_request&.open?
        head = git_client.head_sha(worktree.path)
        return keep(worktree, "HEAD is unavailable") if head.nil?
        return ready(worktree, head) if merged?(head, pull_request)

        keep(worktree, unmerged_reason(pull_request))
      end

      # True when the worktree holds changes that are not committed.
      #
      # An untracked directory that holds a registered worktree is not
      # uncommitted work. Git reports the directory without descending
      # into it, and the worktree inside it is about to be removed.
      def dirty?(worktree, worktree_paths)
        git_client.status_entries(worktree.path).any? do |code, entry|
          next false if code == "??" && holds_worktree?(worktree, entry, worktree_paths)

          true
        end
      end

      def holds_worktree?(worktree, entry, worktree_paths)
        directory = File.expand_path(entry, worktree.path)
        directory = "#{directory}/" unless directory.end_with?("/")

        worktree_paths.any? { |path| path == directory.chomp("/") || path.start_with?(directory) }
      end

      # True when the worktree holds the directory the script runs in.
      #
      # Removing the worktree the caller is standing in would take the
      # caller's own working directory with it.
      def holds_current_directory?(path)
        directory = File.expand_path(path.to_s)
        return true if @current_directory == directory

        directory = "#{directory}/" unless directory.end_with?("/")
        @current_directory.start_with?(directory)
      end

      def ready(worktree, head)
        Candidate.new(worktree: worktree, removable: true, reason: "", head_sha: head)
      end

      def keep(worktree, reason)
        Candidate.new(worktree: worktree, removable: false, reason: reason)
      end

      # True when the branch's work is already in the base branch.
      def merged?(head, pull_request)
        return true if git_client.ancestor?(head, @base_commit)
        return false unless pull_request&.merged?
        return false unless pull_request.head_sha.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/) &&
          pull_request.merge_sha.match?(/\A(?:[0-9a-f]{40}|[0-9a-f]{64})\z/)

        pull_request.base == @base_branch && pull_request.head_sha == head &&
          git_client.ancestor?(pull_request.merge_sha, @base_commit)
      end

      def unmerged_reason(pull_request)
        return "pull request ##{pull_request.number} closed without merging" if pull_request&.closed?

        "not merged into #{base}"
      end

      def delete_branch(candidate, removed_branches, failures)
        worktree = candidate.worktree
        unless git_client.commit_sha("refs/heads/#{worktree.branch}") == candidate.head_sha
          failures << [ worktree.path, "branch #{worktree.branch} changed and was not deleted" ]
          return
        end
        result = git_client.delete_branch(worktree.branch)
        if result.success?
          removed_branches << worktree.branch
          return
        end

        failures << [ worktree.path, "branch #{worktree.branch} was not deleted: #{result.stderr.to_s.strip}" ]
      end
  end
end
