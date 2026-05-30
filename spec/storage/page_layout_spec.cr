require "../spec_helper"

include TrashPandaDB::Storage

private def fresh_leaf : Bytes
  page = Bytes.new(PAGE_SIZE.to_i)
  PageLayout.init_leaf(page)
  page
end

describe TrashPandaDB::Storage::PageLayout do
  describe ".leaf_remove_at" do
    it "resets free_end to PAGE_SIZE when the last cell is removed" do
      page = fresh_leaf
      key  = "hello".to_slice
      val  = Bytes.new(50)
      cs   = PageLayout.leaf_cell_byte_size(key, val)
      fe   = PAGE_SIZE.to_i - cs
      PageLayout.write_leaf_cell(page, fe, key, val)
      PageLayout.set_cell_ptr(page, 0, fe.to_u16)
      PageLayout.leaf_set_cell_count(page, 1_u16)
      PageLayout.leaf_set_free_end(page, fe.to_u16)

      PageLayout.leaf_remove_at(page, 0)

      PageLayout.leaf_cell_count(page).should eq 0_u16
      PageLayout.leaf_free_end(page).should eq PAGE_SIZE.to_u16
      PageLayout.leaf_has_room?(page, cs).should be_true
    end

    it "repacks remaining cell to the end and reports correct free_end" do
      page  = fresh_leaf
      key_a = "aaa".to_slice
      key_b = "bbb".to_slice
      val   = Bytes.new(50, 0xAB_u8)
      cs_a  = PageLayout.leaf_cell_byte_size(key_a, val)
      cs_b  = PageLayout.leaf_cell_byte_size(key_b, val)

      # Pack two cells from the end: a at top, b below it.
      fe_a = PAGE_SIZE.to_i - cs_a
      PageLayout.write_leaf_cell(page, fe_a, key_a, val)
      fe_b = fe_a - cs_b
      PageLayout.write_leaf_cell(page, fe_b, key_b, val)
      PageLayout.set_cell_ptr(page, 0, fe_a.to_u16)
      PageLayout.set_cell_ptr(page, 1, fe_b.to_u16)
      PageLayout.leaf_set_cell_count(page, 2_u16)
      PageLayout.leaf_set_free_end(page, fe_b.to_u16)

      # Remove cell a (index 0). b must survive, repacked flush to the end.
      PageLayout.leaf_remove_at(page, 0)

      PageLayout.leaf_cell_count(page).should eq 1_u16
      PageLayout.leaf_free_end(page).should eq (PAGE_SIZE.to_i - cs_b).to_u16
      k, v = PageLayout.read_leaf_cell(page, PageLayout.cell_ptr(page, 0).to_i)
      k.to_a.should eq key_b.to_a
      v.to_a.should eq val.to_a
    end

    it "allows immediate re-insert after removing all cells from a full page" do
      page  = fresh_leaf
      key   = "k".to_slice
      val   = Bytes.new(80)
      cs    = PageLayout.leaf_cell_byte_size(key, val)
      count = 0
      fe    = PAGE_SIZE.to_i

      # Fill the page to capacity.
      while PageLayout.leaf_has_room?(page, cs)
        fe -= cs
        PageLayout.write_leaf_cell(page, fe, key, val)
        PageLayout.set_cell_ptr(page, count, fe.to_u16)
        PageLayout.leaf_set_cell_count(page, (count + 1).to_u16)
        PageLayout.leaf_set_free_end(page, fe.to_u16)
        count += 1
      end
      PageLayout.leaf_has_room?(page, cs).should be_false

      # Remove every cell.
      count.times { PageLayout.leaf_remove_at(page, 0) }

      PageLayout.leaf_cell_count(page).should eq 0_u16
      # Must report room again — regression for the page-bloat bug.
      PageLayout.leaf_has_room?(page, cs).should be_true
    end
  end
end
