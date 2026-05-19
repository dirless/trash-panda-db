require "./spec_helper"

describe "Serialization Debug" do
  it "debugs serialization process" do
    File.delete(DB_FILENAME) rescue nil
    File.delete("#{DB_FILENAME}-wal") rescue nil

    # Create a table and insert data
    DB.open "trashpanda:#{DB_FILENAME}" do |db|
      db.exec "CREATE TABLE test_table (id INTEGER PRIMARY KEY, name TEXT)"
      db.exec "INSERT INTO test_table (name) VALUES (?)", "test"
    end

    # Check what's in the file
    if File.exists?(DB_FILENAME)
      file_size = File.size(DB_FILENAME)
      puts "Database file size: #{file_size} bytes"

      File.open(DB_FILENAME, "rb") do |file|
        # Read and display first 100 bytes in hex
        content = file.read_bytes(100)
        hex_content = content.map { |b| b.to_s(16).rjust(2, '0') }.join(" ")
        puts "First 100 bytes (hex): #{hex_content}"
      end
    else
      puts "Database file does not exist!"
    end

    # Try to reopen and query
    DB.open "trashpanda:#{DB_FILENAME}" do |db|
      tables = db.query_all "SELECT name FROM test_table", as: String rescue [] of String
      puts "Tables found: #{tables}"
    end
  end
end