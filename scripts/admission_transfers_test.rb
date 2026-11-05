require 'minitest/autorun'
require 'nokogiri'
require 'stringio'
require 'tmpdir'
require 'zip'
require_relative 'admission_transfers'

class AdmissionTransfersTest < Minitest::Test
  def test_reimport_on_another_day_keeps_original_record
    record = AdmissionTransfers.to_admissions_record('2024', {
      source_row: 6, institution_code: '0378', institution_name: '安徽财经大学',
      major_code: '01', major_name: '经济学', score: '561'
    })
    original = record.merge('recorded_on' => '2000-01-01')
    fields = AdmissionTransfers::ADMISSIONS_FIELDS
    table = CSV::Table.new([CSV::Row.new(fields, fields.map { |field| original[field] })])
    AdmissionTransfers.stub(:load_admissions_rows, table) do
      assert_equal({ added: 0, skipped: 1 }, AdmissionTransfers.append_admissions_records([record]))
      assert_equal '2000-01-01', table.first['recorded_on']
      changed = record.merge('score' => '562')
      assert_raises(RuntimeError) { AdmissionTransfers.append_admissions_records([changed]) }
    end
  end

  def latest_entry(source_id)
    archive_entries.reverse.find { |item| item['source_id'] == source_id }
  end

  def xlsx_bytes_from_source(source_id)
    entry = latest_entry(source_id)
    refute_nil entry
    path = local_path(entry.fetch('path'))
    return File.binread(path) if File.extname(path).downcase == '.xlsx'

    Zip::File.open(path) do |zip|
      excel_entry = AdmissionTransfers.first_excel_entry(zip)
      return excel_entry.get_input_stream.read
    end
  end

  def rows_from_xlsx_xml(xlsx_bytes)
    parsed_rows = nil
    Zip::File.open_buffer(StringIO.new(xlsx_bytes)) do |xlsx|
      shared_entry = xlsx.find_entry('xl/sharedStrings.xml')
      shared_strings = if shared_entry
                         doc = Nokogiri::XML(shared_entry.get_input_stream.read)
                         doc.xpath('//xmlns:si').map { |node| node.xpath('.//xmlns:t').map(&:text).join }
                       else
                         []
                       end

      sheet_entry = xlsx.find_entry('xl/worksheets/sheet1.xml') || xlsx.glob('xl/worksheets/sheet*.xml').sort_by(&:name).first
      raise 'XLSX worksheet XML missing' unless sheet_entry
      sheet = Nokogiri::XML(sheet_entry.get_input_stream.read)

      rows = []
      sheet.xpath('//xmlns:sheetData/xmlns:row').each do |row_node|
        source_row = row_node['r'].to_i
        next if source_row < 6

        values = Array.new(12)
        row_node.xpath('./xmlns:c').each do |cell|
          reference = cell['r']
          next unless reference
          letters = reference[/\A[A-Z]+/]
          next unless letters
          column = letters.chars.reduce(0) { |sum, char| sum * 26 + char.ord - 64 }
          next if column > 12

          text = case cell['t']
                 when 's'
                   index = cell.at_xpath('./xmlns:v')&.text.to_i
                   shared_strings[index]
                 when 'inlineStr'
                   cell.xpath('./xmlns:is//xmlns:t').map(&:text).join
                 else
                   cell.at_xpath('./xmlns:v')&.text
                 end
          values[column - 1] = text
        end

        normalized = values.map { |item| item.to_s }
        next if normalized.all? { |item| item.strip.empty? }
        required = normalized.first(5)
        next if required.any? { |item| item.strip.empty? }
        next unless required[4].strip.match?(/\A\d+(?:\.0+)?\z/)
        ties = normalized[5, 7].map { |item| item.to_s.strip }
        next unless ties.length == 7 && ties.all? { |item| item.match?(/\A\d+\z/) }
        rows << { source_row: source_row, values: normalized }
      end
      parsed_rows = rows
    end
    parsed_rows
  end

  def test_2024_sheet_structure_and_first_data_row
    entry = latest_entry('SRC-LN-TRANSFER-PHYS-2024')
    refute_nil entry
    result = AdmissionTransfers.read_2024_sheet(local_path(entry.fetch('path')))
    tie_headers = result.fetch(:tie_headers)
    assert_equal ['语数成绩', '语数最高成绩', '外语成绩', '首选科目成绩', '再选科目最高成绩', '再选科目次高成绩', '志愿号'], tie_headers
    row = result.fetch(:rows).first
    assert_equal 6, row[:source_row]
    assert_equal '0378', row[:institution_code]
    assert_equal '安徽财经大学', row[:institution_name]
    assert_equal '01', row[:major_code]
    assert_equal '561', row[:score]
    assert_equal %w[204 111 121 67 87 82 7], row[:tie_values]
  end

  def test_2025_attachment_is_detected_as_encrypted_ole_package
    entry = latest_entry('SRC-LN-TRANSFER-PHYS-2025')
    refute_nil entry
    path = local_path(entry.fetch('path'))
    assert AdmissionTransfers.encrypted_ole_package?(path)
    error = assert_raises(RuntimeError) { AdmissionTransfers.read_2025_sheet(path) }
    assert_includes error.message, 'EncryptedPackage'
  end

  def test_2026_sheet_structure_and_first_data_row
    entry = latest_entry('SRC-LN-TRANSFER-PHYS-2026')
    refute_nil entry
    result = AdmissionTransfers.read_2026_sheet(local_path(entry.fetch('path')))
    tie_headers = result.fetch(:tie_headers)
    assert_equal ['语数成绩', '语数最高成绩', '外语成绩', '首选科目成绩', '再选科目最高成绩', '再选科目次高成绩', '志愿号'], tie_headers
    row = result.fetch(:rows).first
    assert_equal 6, row[:source_row]
    assert_equal '0378', row[:institution_code]
    assert_equal '安徽财经大学', row[:institution_name]
    assert_equal '04', row[:major_code]
    assert_equal '460', row[:score]
    assert_equal %w[202 110 100 22 72 64 3], row[:tie_values]
  end

  def test_data_row_validation_rejects_extra_columns_and_invalid_scores
    valid = %w[0378 安徽财经大学 01 经济学 561 204 111 121 67 87 82 7]
    assert_silent { AdmissionTransfers.validate_data_row!(valid, 6) }

    extra = valid + ['unexpected']
    assert_raises(RuntimeError) { AdmissionTransfers.validate_data_row!(extra, 6) }

    non_integer_score = valid.dup
    non_integer_score[4] = '561.5'
    assert_raises(RuntimeError) { AdmissionTransfers.validate_data_row!(non_integer_score, 6) }

    out_of_range = valid.dup
    out_of_range[4] = '751'
    assert_raises(RuntimeError) { AdmissionTransfers.validate_data_row!(out_of_range, 6) }
  end

  def test_title_year_validation
    assert_silent { AdmissionTransfers.validate_title_year!('辽宁省2026年普通高等学校招生录取普通类本科批（物理学科类）投档最低分', '2026') }
    assert_raises(RuntimeError) { AdmissionTransfers.validate_title_year!('辽宁省普通高等学校招生录取普通类本科批（物理学科类）投档最低分', '2026') }
  end

  def test_xml_cross_check_for_2024_and_2026_matches_parsed_rows
    {
      '2024' => 'SRC-LN-TRANSFER-PHYS-2024',
      '2026' => 'SRC-LN-TRANSFER-PHYS-2026'
    }.each do |year, source_id|
      xml_rows = rows_from_xlsx_xml(xlsx_bytes_from_source(source_id))
      parsed = AdmissionTransfers.load_year_result(year).fetch(:rows)
      assert_equal xml_rows.length, parsed.length, "#{year} row count mismatch"

      parsed.each_with_index do |row, index|
        xml_row = xml_rows[index]
        assert_equal row[:source_row], xml_row[:source_row], "#{year} source row mismatch at index #{index}"
        values = xml_row[:values]
        assert_equal row[:institution_code], values[0].strip, "#{year} institution_code mismatch row #{row[:source_row]}"
        assert_equal row[:institution_name], values[1].strip, "#{year} institution_name mismatch row #{row[:source_row]}"
        assert_equal row[:major_code], values[2].strip, "#{year} major_code mismatch row #{row[:source_row]}"
        assert_equal row[:major_name], values[3].strip, "#{year} major_name mismatch row #{row[:source_row]}"
        assert_equal row[:score], values[4].to_s.sub(/\.0+\z/, '').strip, "#{year} score mismatch row #{row[:source_row]}"
        assert_equal row[:tie_values], values[5, 7].map { |item| item.to_s.strip }, "#{year} tie values mismatch row #{row[:source_row]}"
      end
    end
  end
end