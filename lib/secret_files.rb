# frozen_string_literal: true

module SecretFiles
  KEYS = %w[
    SECRET_KEY_BASE
    POSTGRES_PASSWORD
    ACTIVE_RECORD_ENCRYPTION_PRIMARY_KEY
    ACTIVE_RECORD_ENCRYPTION_DETERMINISTIC_KEY
    ACTIVE_RECORD_ENCRYPTION_KEY_DERIVATION_SALT
  ].freeze
  MAX_BYTES = 65_536

  class ConfigurationError < StandardError; end

  module_function

  def load!(env = ENV)
    values = KEYS.each_with_object({}) do |key, result|
      file_key = "#{key}_FILE"
      next unless env.key?(file_key)

      fail_configuration(file_key, "cannot be combined with #{key}") if env.key?(key)
      if key == "SECRET_KEY_BASE" && env.key?("SECRET_KEY_BASE_DUMMY")
        fail_configuration(file_key, "cannot be combined with SECRET_KEY_BASE_DUMMY")
      end
      if key == "POSTGRES_PASSWORD" && env.key?("DATABASE_URL")
        fail_configuration(file_key, "cannot be combined with DATABASE_URL")
      end

      result[key] = read(env[file_key], file_key)
    end

    env.update(values)
  end

  def read(path, file_key)
    unless path.is_a?(String) && path.start_with?("/") && !path.include?("\0")
      fail_configuration(file_key, "must name an absolute readable file")
    end

    # nonblocking open lets us reject special files without waiting on a FIFO.
    value = File.open(path, File::RDONLY | File::NONBLOCK) do |file|
      fail_configuration(file_key, "must name a regular file") unless file.stat.file?
      file.binmode.read(MAX_BYTES + 1) || String.new
    end
    value.force_encoding(Encoding::UTF_8)
    if value.bytesize > MAX_BYTES || !value.valid_encoding? || value.include?("\0") || /\A[[:space:]]*\z/.match?(value)
      fail_configuration(file_key, "must contain nonblank UTF-8 text without NUL bytes, at most #{MAX_BYTES} bytes")
    end

    value
  rescue SystemCallError, IOError, ArgumentError
    fail_configuration(file_key, "could not be read")
  end

  def fail_configuration(file_key, reason)
    raise ConfigurationError, "Invalid #{file_key}: #{reason}", cause: nil
  end
end
