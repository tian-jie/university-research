require 'minitest/autorun'
require 'tmpdir'
require_relative 'research_data'

class ResearchDataTest < Minitest::Test
  def setup
    @original_root = ROOT.dup
    @sandbox = Dir.mktmpdir('research-data-test-')
    documents = CSV.read(File.join(@original_root, 'data/sources.csv'), headers: true).map { |row| row['document_path'] }.compact
    (SCHEMAS.keys + documents + %w[AGENTS.md PLAN.md STATUS.md]).uniq.each do |relative|
      destination = File.join(@sandbox, relative)
      FileUtils.mkdir_p(File.dirname(destination))
      FileUtils.cp(File.join(@original_root, relative), destination)
    end
    ROOT.replace(@sandbox)
  end

  def teardown
    ROOT.replace(@original_root)
    FileUtils.remove_entry(@sandbox)
  end

  def mutate_table(relative)
    path = File.join(ROOT, relative)
    rows = CSV.read(path)
    yield rows
    CSV.open(path, 'w') { |csv| rows.each { |row| csv << row } }
  end

  def assert_check_error(pattern)
    capture_io do
      error = assert_raises(RuntimeError) { check }
      assert_match pattern, error.message
    end
  end

  def test_seed_tables_are_valid
    capture_io { assert_equal SCHEMAS.keys, check.keys }
  end

  def test_wrong_column_count_is_rejected
    mutate_table('data/sources.csv') { |rows| rows[1] << 'unexpected' }
    assert_check_error(/wrong column count/)
  end

  def test_duplicate_ids_are_rejected
    mutate_table('data/sources.csv') { |rows| rows[2][0] = rows[1][0] }
    assert_check_error(/duplicate ID/)
  end

  def test_missing_source_is_rejected
    mutate_table('data/programmes.csv') { |rows| rows[1][rows[0].index('source_ids')] = nil }
    assert_check_error(/missing source/)
  end

  def test_unknown_source_is_rejected
    mutate_table('data/programmes.csv') { |rows| rows[1][rows[0].index('source_ids')] = 'SRC-MISSING' }
    assert_check_error(/unknown source/)
  end

  def test_invalid_date_is_rejected
    mutate_table('private/profile.csv') { |rows| rows[1][1] = '2026-02-30' }
    capture_io { assert_raises(ArgumentError) { check } }
  end

  def test_expired_deadline_cannot_be_a_todo
    mutate_table('data/pathways.csv') do |rows|
      rows[1][rows[0].index('action_status')] = 'todo'
      rows[1][rows[0].index('end_date')] = '2000-01-01'
    end
    assert_check_error(/expired date marked todo/)
  end

  def test_spreadsheet_formula_is_rejected
    mutate_table('data/programmes.csv') { |rows| rows[1][4] = '=1+1' }
    assert_check_error(/spreadsheet formula/)
  end

  def test_changed_archive_is_detected
    FileUtils.mkdir_p(File.join(ROOT, 'raw'))
    File.write(File.join(ROOT, 'raw/probe.bin'), 'original')
    entry = { source_id: 'SRC-LN-SELECT-XLSX', path: 'raw/probe.bin', sha256: '0' * 64, retrieved_at: '2026-11-04T00:00:00Z' }
    File.write(File.join(ROOT, 'raw/manifest.jsonl'), JSON.generate(entry) + "\n")
    assert_check_error(/missing or changed/)
  end

  def test_unknown_derived_source_is_rejected
    FileUtils.mkdir_p(File.join(ROOT, 'data/derived'))
    File.write(File.join(ROOT, 'data/derived/manifest.jsonl'), JSON.generate(source_id: 'SRC-MISSING') + "\n")
    assert_check_error(/Derived data has unknown source/)
  end

  def test_pdf_source_format_is_supported
    mutate_table('data/sources.csv') { |rows| rows[1][rows[0].index('archive_format')] = 'pdf' }
    output, = capture_io { check }
    assert_includes output, 'sources.csv:'
  end

  def test_public_data_script_format_is_supported
    mutate_table('data/sources.csv') { |rows| rows[1][rows[0].index('archive_format')] = 'js' }
    output, = capture_io { check }
    assert_includes output, 'sources.csv:'
  end

  def test_backup_contains_public_and_private_tables
    FileUtils.mkdir_p(File.join(ROOT, 'scripts/pdfjs/node_modules/demo'))
    FileUtils.mkdir_p(File.join(ROOT, 'scripts/pdfjs'))
    File.write(File.join(ROOT, 'scripts/pdfjs/package.json'), "{\n  \"name\": \"pdfjs\"\n}\n")
    File.write(File.join(ROOT, 'scripts/pdfjs/package-lock.json'), "{\n  \"name\": \"pdfjs\",\n  \"lockfileVersion\": 3\n}\n")
    File.write(File.join(ROOT, 'scripts/pdfjs/node_modules/demo/index.js'), 'module.exports = 1;')

    capture_io { backup }
    archives = Dir.glob(File.join(ROOT, 'backups/*.tar.gz'))
    assert_equal 1, archives.length
    contents, error, result = Open3.capture3('tar', '-tzf', archives.first)
    assert result.success?, error
    lines = contents.lines.map(&:strip)
    assert_includes lines, 'data/sources.csv'
    assert_includes lines, 'private/profile.csv'
    assert_includes lines, 'data/NATIONAL_SAMPLES.md'
    assert_includes lines, 'AGENTS.md'
    assert_includes lines, 'PLAN.md'
    assert_includes lines, 'STATUS.md'
    assert_includes lines, 'scripts/pdfjs/package.json'
    assert_includes lines, 'scripts/pdfjs/package-lock.json'
    refute(lines.any? { |line| line.include?('scripts/pdfjs/node_modules/') }, 'backup unexpectedly includes node_modules')
  end
end