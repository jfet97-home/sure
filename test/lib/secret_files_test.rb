# frozen_string_literal: true

require "test_helper"
require "open3"
require "tmpdir"
require_relative "../../lib/secret_files"

class SecretFilesTest < ActiveSupport::TestCase
  test "leaves environment-only installations unchanged" do
    env = { "SECRET_KEY_BASE" => "existing", "OTHER_FILE" => "/missing" }

    SecretFiles.load!(env)

    assert_equal({ "SECRET_KEY_BASE" => "existing", "OTHER_FILE" => "/missing" }, env)
  end

  test "loads each supported input without trimming or interpreting its contents" do
    with_file(" \tquotes: ' \" # $HOME \\n\r\n ") do |path|
      SecretFiles::KEYS.each do |key|
        env = { "#{key}_FILE" => path }
        SecretFiles.load!(env)
        assert_equal File.binread(path), env[key]
      end
    end
  end

  test "rejects direct and file sources even when the direct value is empty" do
    SecretFiles::KEYS.each do |key|
      [ "", "existing" ].each do |value|
        error = assert_raises(SecretFiles::ConfigurationError) do
          SecretFiles.load!(key => value, "#{key}_FILE" => "/private/path")
        end
        assert_includes error.message, "cannot be combined with #{key}"
        refute_includes error.message, "/private/path"
      end
    end
  end

  test "rejects alternate Rails sources that bypass the configured file" do
    { "SECRET_KEY_BASE" => "SECRET_KEY_BASE_DUMMY", "POSTGRES_PASSWORD" => "DATABASE_URL" }.each do |key, alternate|
      assert_raises(SecretFiles::ConfigurationError) do
        SecretFiles.load!("#{key}_FILE" => "/private/path", alternate => "configured")
      end
    end
  end

  test "rejects empty relative missing and nonregular file paths" do
    Dir.mktmpdir do |directory|
      fifo = File.join(directory, "fifo")
      system("mkfifo", fifo, exception: true)
      [ "", "relative", "bad\0path", File.join(directory, "missing"), directory, fifo, "/dev/null" ].each do |path|
        error = assert_raises(SecretFiles::ConfigurationError) { SecretFiles.load!("SECRET_KEY_BASE_FILE" => path) }
        assert_nil error.cause
        refute_includes error.message, directory
      end
    end
  end

  test "sanitizes unreadable file errors" do
    File.expects(:open).raises(Errno::EACCES, "/private/sensitive-path")

    error = assert_raises(SecretFiles::ConfigurationError) do
      SecretFiles.load!("SECRET_KEY_BASE_FILE" => "/private/sensitive-path")
    end

    assert_equal "Invalid SECRET_KEY_BASE_FILE: could not be read", error.message
    assert_nil error.cause
  end

  test "rejects invalid contents before updating any inputs" do
    [ "", " \t\r\n", "\u00a0", "\u0085\u2007\u2028\u2029\u3000", "secret\0text", "\xff".b, "a" * (SecretFiles::MAX_BYTES + 1) ].each do |content|
      with_file(content) do |path|
        env = { "SECRET_KEY_BASE_FILE" => path }
        assert_raises(SecretFiles::ConfigurationError) { SecretFiles.load!(env) }
        refute env.key?("SECRET_KEY_BASE")
      end
    end
    with_file("valid") do |path|
      env = { "SECRET_KEY_BASE_FILE" => path, "POSTGRES_PASSWORD_FILE" => "/missing" }
      assert_raises(SecretFiles::ConfigurationError) { SecretFiles.load!(env) }
      refute env.key?("SECRET_KEY_BASE")
    end
  end

  test "three Unicode blank encryption files abort boot instead of selecting fallback keys" do
    with_file("\u00a0") do |path|
      env = SecretFiles::KEYS.flat_map { |key| [ [ key, nil ], [ "#{key}_FILE", nil ] ] }.to_h
        .merge("SECRET_KEY_BASE" => "synthetic-key", "SECRET_KEY_BASE_DUMMY" => nil, "RAILS_ENV" => "production")
      ActiveRecordEncryptionConfig::ENV_KEYS.each { |key| env["#{key}_FILE"] = path }

      output, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", 'require_relative "config/environment"', chdir: Rails.root)

      refute status.success?
      assert_includes output, "Invalid ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY_FILE"
      assert_includes output, "must contain nonblank UTF-8 text"
    end
  end

  test "file configuration preserves boot database sessions and encryption after dotenv" do
    Dir.mktmpdir do |directory|
      values = SecretFiles::KEYS.index_with { |key| "synthetic-#{key.downcase}" }
      values["POSTGRES_PASSWORD"] = " \tpassword: # ' \" \\\nnext line\n \u007f\u0085\u0086\u009f\u2028\u2029\ufffe\uffff\u{1f600}\u{10ffff}"
      env = SecretFiles::KEYS.flat_map { |key| [ [ key, nil ], [ "#{key}_FILE", nil ] ] }.to_h
        .merge("SECRET_KEY_BASE_DUMMY" => nil, "DATABASE_URL" => nil, "RAILS_ENV" => "test")
      expected_path = File.join(directory, "expected.json")
      File.write(expected_path, values.to_json)
      fixture_path = File.join(directory, "compatibility.json")
      script = <<~RUBY
        require_relative "config/boot"
        require "rails/all"
        Bundler.require(*Rails.groups)
        Dotenv::Rails.files = [ARGV.fetch(0)]
        require_relative "config/environment"
        expected = JSON.parse(File.read(ARGV.fetch(1)))
        abort "input mismatch" unless expected.all? { |key, value| ENV[key] == value }
        abort "session key mismatch" unless Rails.application.secret_key_base == expected.fetch("SECRET_KEY_BASE")
        database = ActiveRecord::Base.configurations.configs_for(env_name: "test").first
        abort "database password mismatch" unless database.configuration_hash[:password] == expected.fetch("POSTGRES_PASSWORD")
        abort "explicit encryption disabled" unless ActiveRecordEncryptionConfig.explicitly_configured?
        verifier = Rails.application.message_verifier("file-compatibility")
        if File.exist?(ARGV.fetch(2))
          fixture = JSON.parse(File.read(ARGV.fetch(2)))
          abort "session signature changed" unless verifier.verify(fixture.fetch("signed")) == "synthetic-session"
          abort "encrypted data changed" unless ActiveRecord::Encryption.encryptor.decrypt(fixture.fetch("ciphertext")) == "synthetic-token"
        else
          File.write(ARGV.fetch(2), JSON.generate(
            signed: verifier.generate("synthetic-session"),
            ciphertext: ActiveRecord::Encryption.encryptor.encrypt("synthetic-token")
          ))
        end
        puts "boot compatibility verified"
      RUBY
      dotenv_path = File.join(directory, ".env.test")
      File.write(dotenv_path, "")
      output, status = Open3.capture2e(env.merge(values), "bundle", "exec", "ruby", "-e", script, dotenv_path, expected_path, fixture_path, chdir: Rails.root)
      assert status.success?, output

      File.write(dotenv_path, values.map { |key, value|
        path = File.join(directory, key)
        File.binwrite(path, value)
        "#{key}_FILE=#{path}"
      }.join("\n"))
      output, status = Open3.capture2e(env, "bundle", "exec", "ruby", "-e", script, dotenv_path, expected_path, fixture_path, chdir: Rails.root)
      assert status.success?, output
      assert_includes output, "boot compatibility verified"
    end
  end

  private
    def with_file(contents)
      Tempfile.create("sure-secret") do |file|
        file.binmode
        file.write(contents)
        file.close
        yield file.path
      end
    end
end
