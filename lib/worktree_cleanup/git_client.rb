# frozen_string_literal: true

require "open3"

module WorktreeCleanup
  # Reads git facts about linked worktrees.
  #
  # Every command runs through an argument list. No command is assembled
  # into a shell string, so a path or a branch name can never be
  # interpreted as shell syntax.
  class GitClient
    class Error < StandardError; end

    # A completed git command: its output and its exit status.
    Command = Struct.new(:stdout, :stderr, :status) do
      def success?
        status.success?
      end
    end

    # A linked worktree as git reports it.
    Worktree = Struct.new(:path, :branch, :detached, :bare, keyword_init: true) do
      # True when the worktree has a branch checked out.
      def branched?
        !branch.to_s.empty?
      end

      # True when the worktree has commits that are not in the base branch.
      def detached?
        detached == true
      end

      # The number of path segments. A worktree nested inside another
      # worktree has more segments than the one that holds it.
      def depth
        path.to_s.split("/").length
      end
    end

    def initialize(directory: ".")
      @directory = directory
    end

    # The linked worktrees, with the main checkout first.
    def worktrees
      output = run("worktree", "list", "--porcelain", "-z")
      raise Error, "cannot read worktrees: #{output.stderr.strip}" unless output.success?

      parse_worktrees(output.stdout)
    end

    # The staged, unstaged, untracked, and ignored entries of a worktree.
    #
    # Each entry is the porcelain status code and the path, relative to
    # the worktree root. The code is two characters: the first is the
    # index state, the second is the working tree state. `??` marks an
    # untracked path and `!!` marks an ignored path. NUL separators retain
    # whitespace and special characters without Git's quoted-path encoding.
    def status_entries(path)
      flags = run("ls-files", "-v", "-z", directory: path)
      raise Error, "cannot inspect index for #{path}: #{flags.stderr.strip}" unless flags.success?
      hidden = flags.stdout.split("\0").filter_map do |entry|
        [ "hidden", entry[2..] ] if entry.match?(/\A(?:[a-z]|S) /)
      end
      output = run("status", "--porcelain", "-z", "--ignored", "--untracked-files=all", directory: path)
      raise Error, "cannot inspect #{path}: #{output.stderr.strip}" unless output.success?

      hidden + output.stdout.split("\0").filter_map do |entry|
        next if entry.empty?

        [ entry[0..1], entry[3..].to_s ]
      end
    end

    # The commit the worktree has checked out.
    def head_sha(path)
      output = run("rev-parse", "HEAD", directory: path)
      return nil unless output.success?

      output.stdout.strip
    end

    def commit_sha(ref)
      output = run("rev-parse", "--verify", "--quiet", "--end-of-options", "#{ref}^{commit}")
      output.stdout.strip if output.success?
    end

    def base_branch(base)
      output = run("rev-parse", "--symbolic-full-name", "--verify", "--end-of-options", base)
      return nil unless output.success?

      ref = output.stdout.strip
      target = run("symbolic-ref", "--quiet", ref)
      ref = target.stdout.strip if target.success?
      return ref.delete_prefix("refs/heads/") if ref.start_with?("refs/heads/")

      ref.sub(%r{\Arefs/remotes/[^/]+/}, "") if ref.start_with?("refs/remotes/")
    end

    # True when the commit is an ancestor of the base ref.
    #
    # A branch that was merged into the base branch has its commits
    # reachable from the base ref, so the check proves the merge without
    # asking the forge.
    def ancestor?(sha, base)
      return false if sha.to_s.empty? || base.to_s.empty?

      run("merge-base", "--is-ancestor", sha, base).success?
    end

    # Removes a linked worktree.
    #
    # The worktree must be clean. Git refuses to remove a worktree that
    # has changes, which is the last guard before a removal.
    def remove_worktree(path)
      run("worktree", "remove", path)
    end

    # Deletes a local branch.
    def delete_branch(branch)
      run("branch", "-D", branch)
    end

    # Removes the administrative entries of worktrees whose directories
    # are already gone.
    def prune
      run("worktree", "prune")
    end

    private
      def run(*arguments, directory: @directory)
        stdout, stderr, status = Open3.capture3("git", "-C", directory, *arguments)
        Command.new(stdout, stderr, status)
      rescue Errno::ENOENT
        raise Error, "Git is unavailable or the repository directory does not exist: #{directory}"
      end

      # Reads the porcelain worktree listing.
      #
      # Each worktree is a block of NUL-separated fields. The
      # block starts with the path, and names the branch when one is
      # checked out. A worktree with no branch is detached.
      def parse_worktrees(output)
        output.split("\0\0").filter_map { |block| parse_block(block) }
      end

      # Reads one worktree block.
      def parse_block(block)
        lines = block.split("\0")
        path = lines.find { |line| line.start_with?("worktree ") }&.delete_prefix("worktree ")
        return nil if path.nil?

        Worktree.new(
          path: path,
          branch: branch_of(lines),
          detached: lines.include?("detached"),
          bare: lines.include?("bare")
        )
      end

      # The branch checked out in a worktree block, or nil.
      def branch_of(lines)
        line = lines.find { |candidate| candidate.start_with?("branch ") }
        return nil if line.nil?

        line.delete_prefix("branch ").delete_prefix("refs/heads/")
      end
  end
end
