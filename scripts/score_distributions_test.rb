require 'minitest/autorun'
require_relative 'score_distributions'

class ScoreDistributionsTest < Minitest::Test
  def test_parse_score_label_variants
    assert_equal({ score_min: 600, score_max: 600, band_kind: 'single_score_band' }, ScoreDistributions.parse_score_label('600'))
    assert_equal({ score_min: 708, score_max: 750, band_kind: 'aggregated_band' }, ScoreDistributions.parse_score_label('708及以上'))
    assert_equal({ score_min: 708, score_max: 750, band_kind: 'aggregated_band' }, ScoreDistributions.parse_score_label('708分及以上'))
    assert_equal({ score_min: nil, score_max: 200, band_kind: 'aggregated_band' }, ScoreDistributions.parse_score_label('200及以下'))
    assert_nil ScoreDistributions.parse_score_label('分数')
    assert_nil ScoreDistributions.parse_score_label('其他701及以上')
  end

  def test_validate_bands_calculates_ranks_and_allows_zero_count_rows
    bands = [
      { score_label: '708及以上', score_min: 708, score_max: 750, count: 10, cumulative: 10, band_kind: 'aggregated_band' },
      { score_label: '707', score_min: 707, score_max: 707, count: 0, cumulative: 10, band_kind: 'single_score_band' },
      { score_label: '706', score_min: 706, score_max: 706, count: 2, cumulative: 12, band_kind: 'single_score_band' }
    ]

    ScoreDistributions.validate_bands!('2026', bands)
    assert_equal 1, bands[0][:rank_start]
    assert_equal 10, bands[0][:rank_end]
    assert_nil bands[1][:rank_start]
    assert_nil bands[1][:rank_end]
    assert_equal 11, bands[2][:rank_start]
    assert_equal 12, bands[2][:rank_end]
  end

  def test_validate_bands_rejects_cumulative_and_continuity_errors
    cumulative_error = [
      { score_label: '708及以上', score_min: 708, score_max: 750, count: 10, cumulative: 10, band_kind: 'aggregated_band' },
      { score_label: '707', score_min: 707, score_max: 707, count: 2, cumulative: 13, band_kind: 'single_score_band' }
    ]
    assert_raises(RuntimeError) { ScoreDistributions.validate_bands!('2026', cumulative_error) }

    continuity_error = [
      { score_label: '708及以上', score_min: 708, score_max: 750, count: 10, cumulative: 10, band_kind: 'aggregated_band' },
      { score_label: '706', score_min: 706, score_max: 706, count: 2, cumulative: 12, band_kind: 'single_score_band' }
    ]
    assert_raises(RuntimeError) { ScoreDistributions.validate_bands!('2026', continuity_error) }
  end

  def test_validate_bands_rejects_known_bounds_after_unknown_lower_bound
    bands = [
      { score_label: '708及以上', score_min: 708, score_max: 750, count: 10, cumulative: 10, band_kind: 'aggregated_band' },
      { score_label: '150及以下', score_min: nil, score_max: 150, count: 2, cumulative: 12, band_kind: 'aggregated_band' },
      { score_label: '149', score_min: 149, score_max: 149, count: 1, cumulative: 13, band_kind: 'single_score_band' }
    ]
    assert_raises(RuntimeError) { ScoreDistributions.validate_bands!('2026', bands) }
  end

  def test_expand_zero_count_gaps_inserts_missing_single_scores
    bands = [
      { year: '2026', source_id: 'SRC-LN-DISTRIBUTION-PHYS-2026', source_path: 'x', score_label: '152', score_min: 152, score_max: 152, count: 2, cumulative: 100, band_kind: 'single_score_band' },
      { year: '2026', source_id: 'SRC-LN-DISTRIBUTION-PHYS-2026', source_path: 'x', score_label: '150', score_min: 150, score_max: 150, count: 7, cumulative: 107, band_kind: 'single_score_band' }
    ]

    ScoreDistributions.expand_zero_count_gaps!('2026', bands)
    assert_equal %w[152 151 150], bands.map { |band| band[:score_label] }
    middle = bands[1]
    assert_equal 0, middle[:count]
    assert_equal 100, middle[:cumulative]
    assert_equal true, middle[:inferred_zero_gap]
  end

  def test_expand_zero_count_gaps_rejects_unknown_missing_counts
    bands = [
      { year: '2026', source_id: 'SRC-LN-DISTRIBUTION-PHYS-2026', source_path: 'x', score_label: '152', score_min: 152, score_max: 152, count: 2, cumulative: 100, band_kind: 'single_score_band', inferred_zero_gap: false },
      { year: '2026', source_id: 'SRC-LN-DISTRIBUTION-PHYS-2026', source_path: 'x', score_label: '150', score_min: 150, score_max: 150, count: 7, cumulative: 109, band_kind: 'single_score_band', inferred_zero_gap: false }
    ]

    error = assert_raises(RuntimeError) { ScoreDistributions.expand_zero_count_gaps!('2026', bands) }
    assert_includes error.message, 'unknown missing score rows'
  end

  def test_extract_real_pdf_year_2026
    entry = ScoreDistributions.load_manifest_entry('SRC-LN-DISTRIBUTION-PHYS-2026')
    result = ScoreDistributions.extract_bands_for_year('2026', 'SRC-LN-DISTRIBUTION-PHYS-2026', local_path(entry.fetch('path')))
    assert result[:page_count] >= 1
    assert result[:bands].length > 100
    assert_includes result[:title], '2026'
    assert(result[:bands].any? { |band| band[:score_label].include?('及以上') })
    assert(result[:footnotes].any? { |line| line.include?('政策加分') })
  end

  def test_match_admissions_does_not_cross_year
    fields = ::SCHEMAS.fetch('data/admissions.csv')
    row_2024 = Hash[fields.product([''])].merge(
      'record_id' => 'LN-T2024-6',
      'admission_year' => '2024',
      'source_ids' => 'SRC-LN-TRANSFER-NOTICE-2024|SRC-LN-TRANSFER-PHYS-2024',
      'institution_code' => '0378',
      'institution_name' => '安徽财经大学',
      'major_code' => '01',
      'major_name' => '经济学',
      'score' => '708'
    )
    row_2026 = Hash[fields.product([''])].merge(
      'record_id' => 'LN-T2026-6',
      'admission_year' => '2026',
      'source_ids' => 'SRC-LN-TRANSFER-NOTICE-2026|SRC-LN-TRANSFER-PHYS-2026',
      'institution_code' => '0378',
      'institution_name' => '安徽财经大学',
      'major_code' => '04',
      'major_name' => '保险学',
      'score' => '706'
    )
    table = CSV::Table.new([
      CSV::Row.new(fields, fields.map { |field| row_2024[field] }),
      CSV::Row.new(fields, fields.map { |field| row_2026[field] })
    ])

    bands_by_year = {
      '2024' => [
        { source_id: 'SRC-LN-DISTRIBUTION-PHYS-2024', score_label: '708及以上', score_min: 708, score_max: 750, count: 11, rank_start: 1, rank_end: 11, band_kind: 'aggregated_band', page_number: 1, row_position: 1, inferred_zero_gap: false }
      ],
      '2026' => [
        { source_id: 'SRC-LN-DISTRIBUTION-PHYS-2026', score_label: '706', score_min: 706, score_max: 706, count: 2, rank_start: 15, rank_end: 16, band_kind: 'single_score_band', page_number: 1, row_position: 3, inferred_zero_gap: false }
      ]
    }

    ScoreDistributions.stub(:load_admissions_rows, table) do
      result = ScoreDistributions.match_admissions(bands_by_year)
      refs = result[:references]
      assert_equal 2, refs.length
      assert_equal 'aggregated_band', refs.find { |row| row['record_id'] == 'LN-T2024-6' }['rank_kind']
      assert_equal 'single_score_band', refs.find { |row| row['record_id'] == 'LN-T2026-6' }['rank_kind']
    end
  end

  def test_match_admissions_treats_zero_count_band_as_unmatched
    fields = ::SCHEMAS.fetch('data/admissions.csv')
    row_2026 = Hash[fields.product([''])].merge(
      'record_id' => 'LN-T2026-999',
      'admission_year' => '2026',
      'source_ids' => 'SRC-LN-TRANSFER-NOTICE-2026|SRC-LN-TRANSFER-PHYS-2026',
      'institution_code' => '9999',
      'institution_name' => '测试大学',
      'major_code' => '01',
      'major_name' => '测试专业',
      'score' => '706'
    )
    table = CSV::Table.new([
      CSV::Row.new(fields, fields.map { |field| row_2026[field] })
    ])

    bands_by_year = {
      '2024' => [],
      '2026' => [
        { source_id: 'SRC-LN-DISTRIBUTION-PHYS-2026', score_label: '706', score_min: 706, score_max: 706, count: 0, cumulative: 10, rank_start: nil, rank_end: nil, band_kind: 'single_score_band', page_number: 1, row_position: 3, inferred_zero_gap: false }
      ]
    }

    ScoreDistributions.stub(:load_admissions_rows, table) do
      result = ScoreDistributions.match_admissions(bands_by_year)
      ref = result.fetch(:references).first
      assert_equal 'unmatched', ref.fetch('rank_kind')
      assert_nil ref.fetch('rank_start')
      assert_nil ref.fetch('rank_end')
      assert_equal 1, result.fetch(:summary).fetch('2026').fetch(:unmatched)
    end
  end
end
