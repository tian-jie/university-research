require_relative 'research_data'
require 'open3'
require 'set'
require 'tmpdir'

gem 'pdf-reader', '2.16.0'
require 'pdf/reader'

module ScoreDistributions
  YEARS = {
    '2024' => {
      notice_source_id: 'SRC-LN-DISTRIBUTION-NOTICE-2024',
      source_id: 'SRC-LN-DISTRIBUTION-PHYS-2024',
      transfer_source_id: 'SRC-LN-TRANSFER-PHYS-2024'
    },
    '2025' => {
      notice_source_id: 'SRC-LN-DISTRIBUTION-NOTICE-2025',
      source_id: 'SRC-LN-DISTRIBUTION-PHYS-2025',
      transfer_source_id: 'SRC-LN-TRANSFER-PHYS-2025'
    },
    '2026' => {
      notice_source_id: 'SRC-LN-DISTRIBUTION-NOTICE-2026',
      source_id: 'SRC-LN-DISTRIBUTION-PHYS-2026',
      transfer_source_id: 'SRC-LN-TRANSFER-PHYS-2026'
    }
  }.freeze

  BAND_FIELDS = %w[
    source_id year page_number row_y row_position score_label score_min score_max count cumulative rank_start rank_end band_kind inferred_zero_gap source_path
  ].freeze

  REF_FIELDS = %w[
    record_id institution_code institution_name major_code major_name year score rank_start rank_end rank_kind
    distribution_source_id distribution_score_label distribution_page distribution_row_position admission_source_ids limitations
  ].freeze

  def self.normalize_text(value)
    value.to_s.gsub(/[\u00A0\s]/, '')
  end

  def self.find_node_binary
    candidates = ['/opt/homebrew/bin/node', '/usr/local/bin/node', 'node']
    candidates.find { |path| path == 'node' ? system('command -v node >/dev/null 2>&1') : File.executable?(path) }
  end

  def self.pdfjs_module_path
    ENV['PDFJS_DIST_PDF_MJS'] || local_path('scripts/pdfjs/node_modules/pdfjs-dist/legacy/build/pdf.mjs')
  end

  def self.load_manifest_entry(source_id)
    entry = archive_entries.reverse.find { |item| item['source_id'] == source_id }
    raise "Archive missing for #{source_id}" unless entry
    path = local_path(entry.fetch('path'))
    raise "Archived file missing: #{entry['path']}" unless File.file?(path)
    actual_sha = Digest::SHA256.file(path).hexdigest
    raise "Archived SHA mismatch for #{source_id}" unless actual_sha == entry.fetch('sha256')
    entry
  end

  def self.parse_integer(text)
    cleaned = text.to_s.gsub(',', '')
    return nil unless cleaned.match?(/\A\d+\z/)
    cleaned.to_i
  end

  def self.parse_score_label(label)
    normalized = normalize_text(label)
    return nil if normalized.empty?
    if normalized.match?(/\A\d+\z/)
      value = normalized.to_i
      return { score_min: value, score_max: value, band_kind: 'single_score_band' }
    end
    if (match = normalized.match(/\A(?<score>\d+)(?:分)?及以上\z/))
      lower = match[:score].to_i
      return { score_min: lower, score_max: 750, band_kind: 'aggregated_band' }
    end
    if (match = normalized.match(/\A(?<score>\d+)(?:分)?及以下\z/))
      upper = match[:score].to_i
      return { score_min: nil, score_max: upper, band_kind: 'aggregated_band' }
    end
    if (match = normalized.match(/\A(?<min>\d+)[-~至](?<max>\d+)\z/))
      lower = match[:min].to_i
      upper = match[:max].to_i
      return { score_min: lower, score_max: upper, band_kind: 'aggregated_band' }
    end
    nil
  end

  def self.extract_rows_with_pdfjs(pdf_path)
    node = find_node_binary
    raise 'Node.js is required for PDF extraction but not found' unless node
    module_path = pdfjs_module_path
    raise "pdfjs-dist module missing: #{module_path}" unless File.file?(module_path)

    script = <<~JS
      const fs = require('fs');

      (async () => {
        const modulePath = process.argv[2];
        const pdfPath = process.argv[3];
        const pdfjs = await import(modulePath);
        const bytes = new Uint8Array(fs.readFileSync(pdfPath));
        const doc = await pdfjs.getDocument({ data: bytes }).promise;
        const pages = [];

        for (let pageNumber = 1; pageNumber <= doc.numPages; pageNumber += 1) {
          const page = await doc.getPage(pageNumber);
          const content = await page.getTextContent();
          const items = content.items
            .map((item) => ({
              text: item.str,
              x: item.transform[4],
              y: item.transform[5],
              w: item.width,
            }))
            .filter((item) => item.text && item.text.trim() !== '');

          const rows = [];
          for (const item of items) {
            let row = rows.find((candidate) => Math.abs(candidate.y - item.y) < 0.8);
            if (!row) {
              row = { y: item.y, items: [] };
              rows.push(row);
            }
            row.items.push(item);
          }

          rows.sort((a, b) => b.y - a.y);
          const mergedRows = rows.map((row) => {
            row.items.sort((a, b) => a.x - b.x);
            const chunks = [];
            for (const item of row.items) {
              const previous = chunks[chunks.length - 1];
              if (!previous) {
                chunks.push({ x: item.x, right: item.x + item.w, text: item.text });
                continue;
              }
              if (item.x - previous.right < 1.2) {
                previous.text += item.text;
                previous.right = item.x + item.w;
              } else {
                chunks.push({ x: item.x, right: item.x + item.w, text: item.text });
              }
            }
            return {
              y: row.y,
              cells: chunks.map((chunk) => ({ x: chunk.x, text: chunk.text })),
            };
          });

          pages.push({ page_number: pageNumber, rows: mergedRows });
        }

        process.stdout.write(JSON.stringify({ page_count: doc.numPages, pages }));
      })().catch((error) => {
        process.stderr.write(String(error) + String.fromCharCode(10));
        process.exit(1);
      });
    JS

    payload = nil
    Dir.mktmpdir('score-distributions-js-') do |tmpdir|
      script_path = File.join(tmpdir, 'extract.js')
      File.write(script_path, script)
      stdout, stderr, status = Open3.capture3(node, script_path, module_path, pdf_path)
      raise "pdfjs extraction failed: #{stderr}" unless status.success?
      json_start = stdout.index('{')
      raise "pdfjs extraction returned no JSON payload: #{stdout}" unless json_start
      payload = JSON.parse(stdout[json_start..])
    end
    payload
  end

  def self.extract_bands_for_year(year, source_id, source_path)
    payload = extract_rows_with_pdfjs(source_path)
    pages = payload.fetch('pages')
    bands = []
    title = nil
    footnotes = []
    sequence = 0

    pages.each do |page|
      page_number = page.fetch('page_number')
      column_layout = nil
      column_bands = Hash.new { |hash, key| hash[key] = [] }
      page.fetch('rows').each do |row|
        cell_objects = row.fetch('cells')
        texts = cell_objects.map { |cell| cell.fetch('text') }
        normalized_text = normalize_text(texts.join(''))
        if title.nil? && normalized_text.include?('物理学科类') && normalized_text.match?(/\d{4}/)
          title = normalized_text
        end
        if column_layout.nil?
          score_cells = cell_objects.select { |cell| normalize_text(cell.fetch('text')) == '分数' }.sort_by { |cell| cell.fetch('x').to_f }
          count_cells = cell_objects.select { |cell| normalize_text(cell.fetch('text')) == '人数' }.sort_by { |cell| cell.fetch('x').to_f }
          cumulative_cells = cell_objects.select { |cell| normalize_text(cell.fetch('text')) == '累计' }.sort_by { |cell| cell.fetch('x').to_f }
          next unless score_cells.length >= 3 && score_cells.length == count_cells.length && score_cells.length == cumulative_cells.length

          column_layout = score_cells.each_with_index.map do |score_cell, idx|
            {
              score_x: score_cell.fetch('x').to_f,
              count_x: count_cells[idx].fetch('x').to_f,
              cumulative_x: cumulative_cells[idx].fetch('x').to_f
            }
          end
          next
        end
        if row.fetch('y') < 40
          footnote = texts.join('').strip
          footnotes << footnote unless footnote.empty?
        end
        next if row.fetch('y') < 30

        row_groups = column_layout.map do |layout|
          score_cell = cell_objects.min_by { |cell| (cell.fetch('x').to_f - layout.fetch(:score_x)).abs }
          count_cell = cell_objects.min_by { |cell| (cell.fetch('x').to_f - layout.fetch(:count_x)).abs }
          cumulative_cell = cell_objects.min_by { |cell| (cell.fetch('x').to_f - layout.fetch(:cumulative_x)).abs }
          next nil if (score_cell.fetch('x').to_f - layout.fetch(:score_x)).abs > 25
          next nil if (count_cell.fetch('x').to_f - layout.fetch(:count_x)).abs > 80
          next nil if (cumulative_cell.fetch('x').to_f - layout.fetch(:cumulative_x)).abs > 80
          [score_cell, count_cell, cumulative_cell].map { |cell| cell.fetch('text').to_s.strip }
        end

        row_groups.each_with_index do |group, group_index|
          next if group.nil? || group.length < 3
          label = group[0]
          count_text = group[1]
          cumulative_text = group[2]
          next if normalize_text(label) == '分数'
          next unless label.match?(/\d/)

          count = parse_integer(count_text)
          cumulative = parse_integer(cumulative_text)
          if count.nil? || cumulative.nil?
            merged_numbers = "#{count_text} #{cumulative_text}".scan(/\d[\d,]*/).map { |item| item.gsub(',', '').to_i }
            merged_numbers = merged_numbers.each_with_index.select { |value, idx| idx.zero? || value != merged_numbers[idx - 1] }.map(&:first)
            if merged_numbers.length >= 2
              count = merged_numbers[0]
              cumulative = merged_numbers[1]
            end
          end
          raise "#{year} page #{page_number} row has non-integer count/cumulative for #{label}" if count.nil? || cumulative.nil?

          score = parse_score_label(label)
          raise "#{year} has unsupported score label: #{label}" if score.nil?

          sequence += 1
          column_bands[group_index] << {
            year: year,
            source_id: source_id,
            source_path: source_path,
            page_number: page_number,
            row_y: format('%.1f', row.fetch('y')),
            row_position: sequence,
            score_label: label,
            score_min: score[:score_min],
            score_max: score[:score_max],
            count: count,
            cumulative: cumulative,
            band_kind: score[:band_kind],
            inferred_zero_gap: false
          }
        end
      end

      column_bands.keys.sort.each do |column_index|
        bands.concat(column_bands.fetch(column_index))
      end
    end

    raise "Missing title row in #{year} PDF" if title.nil?
    raise "PDF title year mismatch for #{year}" unless title.include?(year)
    raise "PDF title does not mention 物理学科类 for #{year}" unless title.include?('物理学科类')
    raise "No score bands extracted for #{year}" if bands.empty?

    expand_zero_count_gaps!(year, bands)
    bands.each_with_index { |band, index| band[:row_position] = index + 1 }

    validate_bands!(year, bands)
    { title: title, page_count: payload.fetch('page_count'), footnotes: footnotes.uniq, bands: bands }
  end

  def self.expand_zero_count_gaps!(year, bands)
    index = 1
    while index < bands.length
      previous = bands[index - 1]
      current = bands[index]
      prev_single = previous[:score_min] == previous[:score_max] && !previous[:score_min].nil?
      curr_single = current[:score_min] == current[:score_max] && !current[:score_min].nil?
      unless prev_single && curr_single
        index += 1
        next
      end

      gap = previous[:score_min] - current[:score_max] - 1
      if gap.negative?
        raise "#{year} score order inversion around #{previous[:score_label]} -> #{current[:score_label]}"
      end
      if gap.zero?
        index += 1
        next
      end

      cumulative_delta = current[:cumulative] - previous[:cumulative]
      unless cumulative_delta == current[:count]
        raise "#{year} unknown missing score rows around #{previous[:score_label]} -> #{current[:score_label]}: cumulative delta #{cumulative_delta}, current count #{current[:count]}"
      end

      inserted = []
      gap.times do |offset|
        missing_score = previous[:score_min] - offset - 1
        inserted << {
          year: year,
          source_id: previous[:source_id],
          source_path: previous[:source_path],
          page_number: nil,
          row_y: nil,
          row_position: nil,
          score_label: missing_score.to_s,
          score_min: missing_score,
          score_max: missing_score,
          count: 0,
          cumulative: previous[:cumulative],
          band_kind: 'single_score_band',
          inferred_zero_gap: true
        }
      end
      bands.insert(index, *inserted)
      index += inserted.length + 1
    end
  end

  def self.validate_bands!(year, bands)
    seen_labels = Set.new
    previous_cumulative = 0
    unknown_lower_seen = false

    bands.each_with_index do |band, index|
      label_key = normalize_text(band.fetch(:score_label))
      raise "#{year} duplicate score label: #{band[:score_label]}" if seen_labels.include?(label_key)
      seen_labels << label_key

      count = band.fetch(:count)
      cumulative = band.fetch(:cumulative)
      raise "#{year} has negative count for #{band[:score_label]}" if count.negative?
      raise "#{year} has negative cumulative for #{band[:score_label]}" if cumulative.negative?
      expected = previous_cumulative + count
      raise "#{year} cumulative mismatch for #{band[:score_label]}: expected #{expected}, got #{cumulative}" unless cumulative == expected
      previous_cumulative = cumulative

      min = band[:score_min]
      max = band[:score_max]
      raise "#{year} score range inverted for #{band[:score_label]}" if !min.nil? && !max.nil? && min > max
      [min, max].compact.each do |value|
        raise "#{year} score out of range 0..750 for #{band[:score_label]}" unless value >= 0 && value <= 750
      end

      if band[:band_kind] == 'aggregated_band' && min.nil?
        unknown_lower_seen = true
      elsif unknown_lower_seen
        raise "#{year} has known lower bound rows after unknown lower bound segment"
      end

      if count.zero?
        band[:rank_start] = nil
        band[:rank_end] = nil
      else
        band[:rank_start] = cumulative - count + 1
        band[:rank_end] = cumulative
      end

      next if index.zero?
      previous = bands[index - 1]
      validate_continuity!(year, previous, band)
    end
  end

  def self.validate_continuity!(year, previous, current)
    prev_min = previous[:score_min]
    prev_max = previous[:score_max]
    curr_min = current[:score_min]
    curr_max = current[:score_max]

    return if prev_min.nil? || prev_max.nil? || curr_max.nil?
    return if current[:score_min].nil?

    expected_next = prev_min - 1
    raise "#{year} score continuity gap around #{previous[:score_label]} -> #{current[:score_label]}" unless curr_max == expected_next
  end

  def self.load_admissions_rows
    table = CSV.read(local_path('data/admissions.csv'), headers: true, encoding: 'bom|utf-8')
    raise 'Admissions header mismatch' unless table.headers == SCHEMAS.fetch('data/admissions.csv')
    table
  end

  def self.match_admissions(bands_by_year)
    table = load_admissions_rows
    references = []
    summary = {}

    %w[2024 2026].each do |year|
      config = YEARS.fetch(year)
      rows = table.select do |row|
        row['admission_year'] == year && row['record_id'].start_with?("LN-T#{year}-") && row['source_ids'].to_s.split('|').include?(config[:transfer_source_id])
      end
      institutions = rows.group_by { |row| [row['institution_code'], row['institution_name']] }
      candidates = bands_by_year.fetch(year).select do |band|
        !band[:score_min].nil? && !band[:score_max].nil? && band[:count].to_i.positive?
      end

      counts = { single_score_band: 0, aggregated_band: 0, unmatched: 0 }
      rows.each do |row|
        score = row['score'].to_i
        matched = candidates.select { |band| score >= band[:score_min] && score <= band[:score_max] }
        if matched.length > 1
          raise "Ambiguous score mapping for #{row['record_id']} score #{score} in #{year}"
        end

        if matched.empty?
          counts[:unmatched] += 1
          references << {
            'record_id' => row['record_id'],
            'institution_code' => row['institution_code'],
            'institution_name' => row['institution_name'],
            'major_code' => row['major_code'],
            'major_name' => row['major_name'],
            'year' => row['admission_year'],
            'score' => row['score'],
            'rank_start' => nil,
            'rank_end' => nil,
            'rank_kind' => 'unmatched',
            'distribution_source_id' => YEARS.fetch(year)[:source_id],
            'distribution_score_label' => nil,
            'distribution_page' => nil,
            'distribution_row_position' => nil,
            'admission_source_ids' => row['source_ids'],
            'limitations' => '计分口径待核实，仅供分数映射参考，不代表官方专业最低位次'
          }
          next
        end

        band = matched.first
        kind = band[:band_kind]
        counts[kind.to_sym] += 1
        references << {
          'record_id' => row['record_id'],
          'institution_code' => row['institution_code'],
          'institution_name' => row['institution_name'],
          'major_code' => row['major_code'],
          'major_name' => row['major_name'],
          'year' => row['admission_year'],
          'score' => row['score'],
          'rank_start' => band[:rank_start],
          'rank_end' => band[:rank_end],
          'rank_kind' => kind,
          'distribution_source_id' => band[:source_id],
          'distribution_score_label' => band[:score_label],
          'distribution_page' => band[:page_number],
          'distribution_row_position' => band[:row_position],
          'admission_source_ids' => row['source_ids'],
          'limitations' => '计分口径待核实，仅供分数映射参考，不代表官方专业最低位次'
        }
      end

      summary[year] = {
        admission_records: rows.length,
        institution_groups: institutions.length,
        single_score_band_matches: counts[:single_score_band],
        aggregated_band_matches: counts[:aggregated_band],
        unmatched: counts[:unmatched]
      }
    end

    { references: references, summary: summary }
  end

  def self.write_csv(path, fields, rows)
    CSV.open(path, 'w', encoding: 'UTF-8') do |csv|
      csv << fields
      rows.each { |row| csv << fields.map { |field| row[field] } }
    end
  end

  def self.true_string?(value)
    value.to_s.strip.downcase == 'true'
  end

  def self.load_score_distribution_manifest_entries
    path = local_path('data/derived/score-distributions/manifest.jsonl')
    return [] unless File.file?(path)
    File.readlines(path, chomp: true).reject { |line| line.strip.empty? }.map { |line| JSON.parse(line) }
  end

  def self.expected_reference_rows_by_year
    table = load_admissions_rows
    %w[2024 2026].each_with_object({}) do |year, result|
      transfer_source_id = YEARS.fetch(year).fetch(:transfer_source_id)
      rows = table.select do |row|
        row['admission_year'] == year && row['record_id'].start_with?("LN-T#{year}-") && row['source_ids'].to_s.split('|').include?(transfer_source_id)
      end
      result[year] = rows
    end
  end

  def self.check_output_entry!(entry, archives, expected_rows_by_year)
    Time.iso8601(entry.fetch('generated_at'))
    files = entry.fetch('files')
    sources = entry.fetch('sources')

    files.each do |item|
      path = local_path(item.fetch('path'))
      raise "Missing derived file: #{item['path']}" unless File.file?(path)
      sha = Digest::SHA256.file(path).hexdigest
      raise "Derived hash mismatch: #{item['path']}" unless sha == item.fetch('sha256')
    end

    sources.each do |year, source_info|
      source_path = source_info.fetch('source_path')
      source_id = source_info.fetch('source_id')
      source_sha = source_info.fetch('source_sha256')
      source_entry = archives.find { |item| item['source_id'] == source_id && item['path'] == source_path }
      raise "Missing raw source archive entry for #{source_id}" unless source_entry
      raise "Raw source SHA mismatch for #{source_id}" unless source_entry.fetch('sha256') == source_sha
      raise "Missing raw source file for #{source_id}" unless File.file?(local_path(source_path))

      notice_path = source_info.fetch('notice_path')
      notice_source_id = source_info.fetch('notice_source_id')
      notice_entry = archives.find { |item| item['source_id'] == notice_source_id && item['path'] == notice_path }
      raise "Missing raw notice archive entry for #{notice_source_id}" unless notice_entry
      raise "Missing raw notice file for #{notice_source_id}" unless File.file?(local_path(notice_path))
    end

    bands_file = files.find { |item| item['path'].end_with?('/score-bands.csv') }
    refs_file = files.find { |item| item['path'].end_with?('/admission-rank-reference.csv') }
    summary_file = files.find { |item| item['path'].end_with?('/summary.json') }
    raise 'Missing score-bands.csv in derived manifest' unless bands_file
    raise 'Missing admission-rank-reference.csv in derived manifest' unless refs_file
    raise 'Missing summary.json in derived manifest' unless summary_file

    bands_table = CSV.read(local_path(bands_file.fetch('path')), headers: true, encoding: 'bom|utf-8')
    refs_table = CSV.read(local_path(refs_file.fetch('path')), headers: true, encoding: 'bom|utf-8')
    summary = JSON.parse(File.read(local_path(summary_file.fetch('path')), encoding: 'UTF-8'))
    by_year_summary = summary.fetch('by_year')
    has_inferred = bands_table.headers.include?('inferred_zero_gap')

    bands_by_year = bands_table.group_by { |row| row.fetch('year') }
    bands_by_year.each do |year, rows|
      expected_score_band_count = by_year_summary.fetch(year).fetch('score_band_count')
      raise "Score band count mismatch for #{year}" unless rows.length == expected_score_band_count
    end

    refs_by_year = refs_table.group_by { |row| row.fetch('year') }
    %w[2024 2026].each do |year|
      expected_count = expected_rows_by_year.fetch(year).length
      actual_count = refs_by_year.fetch(year, []).length
      raise "Admission reference count mismatch for #{year}" unless actual_count == expected_count
    end

    return unless has_inferred

    bands_by_year.each do |year, rows|
      previous_cumulative = 0
      inferred_rows = 0
      rows.each do |row|
        count = row.fetch('count').to_i
        cumulative = row.fetch('cumulative').to_i
        raise "Negative count in #{year} score-bands" if count.negative?
        raise "Negative cumulative in #{year} score-bands" if cumulative.negative?
        expected = previous_cumulative + count
        raise "Cumulative mismatch in #{year} score-bands" unless cumulative == expected
        previous_cumulative = cumulative

        if count.zero?
          raise "Zero-count row must have empty rank_start in #{year}" unless row['rank_start'].to_s.empty?
          raise "Zero-count row must have empty rank_end in #{year}" unless row['rank_end'].to_s.empty?
        end

        next unless true_string?(row['inferred_zero_gap'])
        inferred_rows += 1
        raise "Inferred row must have nil page_number in #{year}" unless row['page_number'].to_s.empty?
        raise "Inferred row must have nil row_y in #{year}" unless row['row_y'].to_s.empty?
        raise "Inferred row must be zero-count in #{year}" unless count.zero?
      end

      official_rows = rows.length - inferred_rows
      summary_for_year = by_year_summary.fetch(year)
      raise "official_score_band_rows mismatch for #{year}" unless summary_for_year.fetch('official_score_band_rows') == official_rows
      raise "inferred_zero_gap_rows mismatch for #{year}" unless summary_for_year.fetch('inferred_zero_gap_rows') == inferred_rows
    end

    expected_rows_by_year.each do |year, expected_rows|
      refs = refs_by_year.fetch(year, [])
      expected_index = expected_rows.each_with_object({}) { |row, index| index[row['record_id']] = row }
      band_rows = bands_by_year.fetch(year, [])
      band_index = band_rows.each_with_object({}) do |row, index|
        index[[row['score_label'], row['row_position'].to_s]] = row
      end

      matched_counts = { 'single_score_band' => 0, 'aggregated_band' => 0, 'unmatched' => 0 }
      refs.each do |row|
        expected = expected_index[row.fetch('record_id')]
        raise "Unexpected record_id in references: #{row['record_id']}" unless expected
        %w[institution_code institution_name major_code major_name year score].each do |field|
          expected_value = (field == 'year') ? expected.fetch('admission_year') : expected.fetch(field)
          raise "Reference field mismatch for #{row['record_id']}: #{field}" unless row.fetch(field).to_s == expected_value.to_s
        end

        kind = row.fetch('rank_kind')
        raise "Unknown rank_kind for #{row['record_id']}" unless %w[single_score_band aggregated_band unmatched].include?(kind)
        matched_counts[kind] += 1

        if kind == 'unmatched'
          raise "Unmatched row must have empty rank_start for #{row['record_id']}" unless row['rank_start'].to_s.empty?
          raise "Unmatched row must have empty rank_end for #{row['record_id']}" unless row['rank_end'].to_s.empty?
          next
        end

        key = [row.fetch('distribution_score_label'), row.fetch('distribution_row_position').to_s]
        band = band_index[key]
        raise "Missing mapped band for #{row['record_id']}" unless band
        count = band.fetch('count').to_i
        raise "Mapped zero-count band for #{row['record_id']}" unless count.positive?
        raise "Mapped band kind mismatch for #{row['record_id']}" unless band.fetch('band_kind') == kind

        score = row.fetch('score').to_i
        score_min = band.fetch('score_min').to_i
        score_max = band.fetch('score_max').to_i
        raise "Mapped score out of band for #{row['record_id']}" unless score >= score_min && score <= score_max
        raise "rank_start mismatch for #{row['record_id']}" unless row.fetch('rank_start').to_s == band.fetch('rank_start').to_s
        raise "rank_end mismatch for #{row['record_id']}" unless row.fetch('rank_end').to_s == band.fetch('rank_end').to_s
      end

      summary_ref = summary.fetch('admission_rank_reference').fetch(year)
      raise "single_score_band_matches mismatch for #{year}" unless summary_ref.fetch('single_score_band_matches') == matched_counts.fetch('single_score_band')
      raise "aggregated_band_matches mismatch for #{year}" unless summary_ref.fetch('aggregated_band_matches') == matched_counts.fetch('aggregated_band')
      raise "unmatched mismatch for #{year}" unless summary_ref.fetch('unmatched') == matched_counts.fetch('unmatched')
    end
  end

  def self.check_outputs
    entries = load_score_distribution_manifest_entries
    raise 'No score-distributions manifest entries found' if entries.empty?
    archives = archive_entries
    expected_rows_by_year = expected_reference_rows_by_year
    entries.each { |entry| check_output_entry!(entry, archives, expected_rows_by_year) }
    puts "Score-distributions outputs: #{entries.length} manifest entries verified"
    { manifests: entries.length }
  end

  def self.run(_arguments)
    check

    year_payload = {}
    YEARS.each do |year, config|
      notice = load_manifest_entry(config[:notice_source_id])
      source = load_manifest_entry(config[:source_id])
      source_path = local_path(source.fetch('path'))
      parsed = extract_bands_for_year(year, config[:source_id], source_path)
      year_payload[year] = {
        notice_source_id: config[:notice_source_id],
        notice_path: notice.fetch('path'),
        source_id: config[:source_id],
        source_path: source.fetch('path'),
        source_sha256: source.fetch('sha256'),
        title: parsed.fetch(:title),
        page_count: parsed.fetch(:page_count),
        footnotes: parsed.fetch(:footnotes),
        bands: parsed.fetch(:bands)
      }
    end

    mapping = match_admissions(year_payload.transform_values { |item| item.fetch(:bands) })
    references = mapping.fetch(:references)

    stamp = Time.now.utc
    relative_root = "data/derived/score-distributions/score-distributions-#{stamp.strftime('%Y%m%dT%H%M%SZ')}-#{Process.pid}"
    root = local_path(relative_root)
    raise 'Refusing to overwrite existing score-distributions output' if File.exist?(root)
    FileUtils.mkdir_p(root)

    all_bands = year_payload.keys.sort.flat_map do |year|
      year_payload.fetch(year).fetch(:bands).map do |band|
        {
          'source_id' => band[:source_id],
          'year' => year,
          'page_number' => band[:page_number],
          'row_y' => band[:row_y],
          'row_position' => band[:row_position],
          'score_label' => band[:score_label],
          'score_min' => band[:score_min],
          'score_max' => band[:score_max],
          'count' => band[:count],
          'cumulative' => band[:cumulative],
          'rank_start' => band[:rank_start],
          'rank_end' => band[:rank_end],
          'band_kind' => band[:band_kind],
          'inferred_zero_gap' => band[:inferred_zero_gap],
          'source_path' => year_payload.fetch(year).fetch(:source_path)
        }
      end
    end

    bands_path = File.join(root, 'score-bands.csv')
    write_csv(bands_path, BAND_FIELDS, all_bands)

    references_path = File.join(root, 'admission-rank-reference.csv')
    write_csv(references_path, REF_FIELDS, references)

    summary = {
      generated_at: stamp.iso8601,
      years: year_payload.keys.sort,
      scoring_basis_status: '计分口径待核实，仅供分数映射参考',
      by_year: year_payload.keys.sort.each_with_object({}) do |year, result|
        bands = year_payload.fetch(year).fetch(:bands)
        scores = bands.flat_map { |band| [band[:score_min], band[:score_max]] }.compact
        result[year] = {
          source_id: year_payload.fetch(year).fetch(:source_id),
          source_path: year_payload.fetch(year).fetch(:source_path),
          source_sha256: year_payload.fetch(year).fetch(:source_sha256),
          notice_source_id: year_payload.fetch(year).fetch(:notice_source_id),
          notice_path: year_payload.fetch(year).fetch(:notice_path),
          page_count: year_payload.fetch(year).fetch(:page_count),
          title: year_payload.fetch(year).fetch(:title),
          footnotes: year_payload.fetch(year).fetch(:footnotes),
          score_band_count: bands.length,
          official_score_band_rows: bands.count { |band| !band[:inferred_zero_gap] },
          inferred_zero_gap_rows: bands.count { |band| band[:inferred_zero_gap] },
          score_range_known: scores.empty? ? nil : { min: scores.min, max: scores.max },
          includes_unknown_bound_band: bands.any? { |band| band[:score_min].nil? || band[:score_max].nil? }
        }
      end,
      admission_rank_reference: mapping.fetch(:summary),
      limitations: [
        '2025年投档附件为EncryptedPackage/EncryptionInfo结构，未解密且保留缺口',
        'PDF统计表与专业投档分计分口径未完成官方同口径确认',
        'rank区间为统计表分段累计推导，不是官方发布的专业精确位次'
      ]
    }

    summary_path = File.join(root, 'summary.json')
    File.write(summary_path, JSON.pretty_generate(summary) + "\n")

    files = [
      { path: "#{relative_root}/score-bands.csv", sha256: Digest::SHA256.file(bands_path).hexdigest },
      { path: "#{relative_root}/admission-rank-reference.csv", sha256: Digest::SHA256.file(references_path).hexdigest },
      { path: "#{relative_root}/summary.json", sha256: Digest::SHA256.file(summary_path).hexdigest }
    ]

    run_manifest = {
      generated_at: stamp.iso8601,
      years: year_payload.keys.sort,
      files: files,
      sources: year_payload.transform_values do |item|
        {
          source_id: item.fetch(:source_id),
          source_path: item.fetch(:source_path),
          source_sha256: item.fetch(:source_sha256),
          notice_source_id: item.fetch(:notice_source_id),
          notice_path: item.fetch(:notice_path)
        }
      end
    }

    manifest_path = File.join(root, 'manifest.json')
    File.write(manifest_path, JSON.pretty_generate(run_manifest) + "\n")
    files << { path: "#{relative_root}/manifest.json", sha256: Digest::SHA256.file(manifest_path).hexdigest }

    shared_manifest_path = local_path('data/derived/score-distributions/manifest.jsonl')
    FileUtils.mkdir_p(File.dirname(shared_manifest_path))
    File.open(shared_manifest_path, 'a') { |file| file.puts(JSON.generate(run_manifest)) }

    puts JSON.pretty_generate(summary)
    puts "Output: #{relative_root}"
    { root: relative_root, summary: summary, files: files }
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    command = ARGV.shift
    case command
    when nil, 'run'
      ScoreDistributions.run(ARGV)
    when 'check'
      ScoreDistributions.check_outputs
    else
      raise 'Usage: ruby scripts/score_distributions.rb [run|check]'
    end
  rescue StandardError => error
    warn error.message
    exit 1
  end
end
