# frozen_string_literal: true

require_relative "lib/worktree_cleanup/version"

Gem::Specification.new do |spec|
  spec.name = "worktree_cleanup"
  spec.version = WorktreeCleanup::VERSION
  spec.authors = [ "Ramon Tayag" ]
  spec.summary = "Remove merged Git worktrees without discarding unfinished work."
  spec.description = "A dry-run-first CLI that checks Git worktrees and GitHub pull requests before removing merged checkouts and local branches."
  spec.homepage = "https://github.com/ramontayag/worktree_cleanup"
  spec.license = "MIT"
  spec.required_ruby_version = ">= 3.2"
  spec.files = Dir["lib/**/*.rb", "exe/*", "README.md", "LICENSE", "CHANGELOG.md"]
  spec.bindir = "exe"
  spec.executables = [ "worktree-cleanup" ]
  spec.require_paths = [ "lib" ]
  spec.metadata = {
    "source_code_uri" => spec.homepage,
    "bug_tracker_uri" => "#{spec.homepage}/issues",
    "changelog_uri" => "#{spec.homepage}/blob/main/CHANGELOG.md",
    "rubygems_mfa_required" => "true"
  }
end
