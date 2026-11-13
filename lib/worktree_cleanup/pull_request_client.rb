# frozen_string_literal: true

require "json"
require "open3"

module WorktreeCleanup
  # Reads pull-request facts from the GitHub CLI.
  #
  # The cleanup rules need one fact: is there still an open pull request
  # for this branch, and did a pull request for this branch merge?
  # Local ancestry proves a merge when the branch was merged directly.
  # A squash merge rewrites the commit, so ancestry cannot see it, and
  # the pull request is the only remaining proof.
  class PullRequestClient
    LIMIT = 500
    # A pull request, reduced to the facts the cleanup rules read.
    #
    # Branch names remain data and are never interpolated into shell commands.
    PullRequest = Struct.new(:number, :branch, :state, :base, :head_sha, :merge_sha, keyword_init: true) do
      def merged?
        state == "MERGED"
      end

      def open?
        state == "OPEN"
      end

      def closed?
        state == "CLOSED"
      end
    end

    def initialize(directory: ".", environment: ENV)
      @directory = directory
      @environment = environment
    end

    # The pull request for each branch, or nil when the pull requests
    # could not be read.
    #
    # An open request always keeps a branch. The most recent request is used
    # otherwise, and squash proof also requires its exact head and merge commit.
    def by_branch
      response = list("all")
      open_requests = list("open")
      return nil if response.nil? || open_requests.nil? || open_requests.length >= LIMIT

      (response + open_requests).each_with_object({}) do |payload, branches|
        branch = payload["headRefName"].to_s
        next if branch.empty?

        pull_request = build(payload)
        existing = branches[branch]
        branches[branch] = pull_request if preferred?(pull_request, existing)
      end
    rescue JSON::ParserError
      nil
    end

    private
      def preferred?(pull_request, existing)
        return true if existing.nil?
        return false if existing.open? && !pull_request.open?
        return true if pull_request.open? && !existing.open?

        pull_request.number > existing.number
      end

      def list(state)
        stdout, _stderr, status = Open3.capture3(
          @environment,
          "gh", "pr", "list",
          "--state", state,
          "--limit", LIMIT.to_s,
          "--json", "headRefName,number,state,baseRefName,headRefOid,mergeCommit",
          chdir: @directory
        )
        return nil unless status.success?
        return nil if stdout.strip.empty?

        payload = JSON.parse(stdout)
        payload if payload.is_a?(Array) && payload.all? { |entry| valid_payload?(entry) }
      rescue Errno::ENOENT, JSON::ParserError
        # The `gh` binary is missing. The caller treats the pull request
        # state as unknown, which keeps the worktree.
        nil
      end

      def valid_payload?(payload)
        payload.is_a?(Hash) && payload["number"].is_a?(Integer) && payload["number"].positive? &&
          payload["headRefName"].is_a?(String) && !payload["headRefName"].empty? &&
          payload["baseRefName"].is_a?(String) && !payload["baseRefName"].empty? &&
          %w[OPEN CLOSED MERGED].include?(payload["state"])
      end

      def build(payload)
        PullRequest.new(
          number: payload["number"].to_i,
          branch: payload["headRefName"].to_s,
          state: payload["state"].to_s,
          base: payload["baseRefName"].to_s,
          head_sha: payload["headRefOid"].to_s,
          merge_sha: payload["mergeCommit"].is_a?(Hash) ? payload["mergeCommit"]["oid"].to_s : ""
        )
      end
  end
end
