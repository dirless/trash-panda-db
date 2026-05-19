require "spec"
require "../../src/trash_panda_db/storage/constants"
require "../../src/trash_panda_db/storage/wal"
require "../../src/trash_panda_db/storage/pager"

STORAGE_TEST_FILE = "/tmp/tpdb_test_#{Process.pid}"

def with_tmp_path(&block : String ->)
  path = "#{STORAGE_TEST_FILE}_#{Random.rand(0xFFFF).to_s(16)}"
  begin
    yield path
  ensure
    File.delete(path) rescue nil
    File.delete("#{path}-wal") rescue nil
  end
end
