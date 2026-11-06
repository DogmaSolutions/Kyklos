require 'simplecov-cobertura'

# bashcov adds the scripts no test ran (at 0%) only when its root is an absolute path: with a relative root such as
# `--root .` it lists them by relative path, and SimpleCov's root filter then drops every one of them, so a script no
# test runs never counts against the figure. Make the root absolute here, the one place every bashcov run of this
# plugin reads, whatever --root it was given. (bashcov loads this file after parsing its options, before it lists
# the scripts.)
Bashcov.options.root_directory = File.expand_path(Bashcov.options.root_directory) if defined?(Bashcov) && Bashcov.respond_to?(:options)

SimpleCov.start do
  enable_coverage :line
  track_files "**/*.sh"
  # A symbolic link to a script is another name for a script measured under its own path, not a second script: counting
  # it would report the same lines again at 0%.
  add_filter { |source_file| File.symlink?(source_file.filename) }
  formatter SimpleCov::Formatter::CoberturaFormatter
end
