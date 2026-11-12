# frozen_string_literal: true

require "minitest/autorun"
require "fileutils"
require "open3"
require "rbconfig"
require "rubygems/package"
require "tmpdir"

class PackageTest < Minitest::Test
  ROOT = File.expand_path("..", __dir__)

  def test_built_gem_installs_and_runs_outside_the_source_checkout
    Dir.mktmpdir("worktree-cleanup-package-") do |directory|
      package = File.join(directory, "worktree_cleanup.gem")
      environment = ENV.keys.grep(/\A(?:BUNDLE|BUNDLER)_/).to_h { |key| [ key, nil ] }
        .merge("RUBYOPT" => nil, "RUBYLIB" => nil, "GEM_HOME" => File.join(directory, "gems"),
          "GEM_PATH" => File.join(directory, "gems"))
      stub_bin = File.join(directory, "bin")
      FileUtils.mkdir_p(stub_bin)
      File.write(File.join(stub_bin, "gh"), "#!/bin/sh\nprintf '[]\\n'\n")
      File.chmod(0o755, File.join(stub_bin, "gh"))
      environment["PATH"] = "#{stub_bin}:#{ENV.fetch('PATH')}"

      run_command(environment, RbConfig.ruby, "-S", "gem", "build",
        File.join(ROOT, "worktree_cleanup.gemspec"), "--output", package, chdir: ROOT)
      specification = Gem::Package.new(package).spec
      assert_equal "worktree_cleanup", specification.name
      assert_equal "MIT", specification.license
      assert_equal [ "worktree-cleanup" ], specification.executables
      assert_empty specification.runtime_dependencies
      %w[README.md LICENSE CHANGELOG.md].each { |name| assert_includes specification.files, name }

      run_command(environment, RbConfig.ruby, "-S", "gem", "install", "--local", "--no-document",
        "--install-dir", environment.fetch("GEM_HOME"), package, chdir: directory)
      executable = File.join(environment.fetch("GEM_HOME"), "bin", "worktree-cleanup")
      version = run_command(environment, executable, "--version", chdir: directory)
      assert_equal "worktree-cleanup #{specification.version}\n", version
      help = run_command(environment, executable, "--help", chdir: directory)
      assert_includes help, "Usage: worktree-cleanup"

      repo = File.join(directory, "arbitrary repository")
      run_command(environment, "git", "init", "--initial-branch=main", repo, chdir: directory)
      run_command(environment, "git", "-C", repo, "-c", "user.name=Package Test",
        "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
        "commit", "--allow-empty", "-m", "seed", chdir: directory)
      report = run_command(environment, executable, "--repo", repo, "--base", "main", chdir: directory)
      assert_includes report, "Base ref: main"
      assert_includes report, "Dry run. Nothing was removed."
    end
  end

  private
    def run_command(environment, *command, chdir:)
      stdout, stderr, status = Open3.capture3(environment, *command, chdir: chdir)
      assert status.success?, "#{command.join(' ')} failed:\n#{stdout}\n#{stderr}"
      stdout
    end
end
