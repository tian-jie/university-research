require 'minitest/autorun'
require_relative 'subject_requirements'

class SubjectRequirementsTest < Minitest::Test
  SELECTED = %w[物理 化学 生物].freeze

  def test_unrestricted
    assert_equal 'eligible', SubjectRequirements.classify('不提科目要求', SELECTED)[:status]
  end

  def test_both_physics_and_chemistry_are_required
    rule = '物理,化学(2门科目考生均须选考方可报考)'
    assert_equal 'eligible', SubjectRequirements.classify(rule, SELECTED)[:status]
    result = SubjectRequirements.classify(rule, %w[物理 生物 地理])
    assert_equal 'ineligible', result[:status]
    assert_equal ['化学'], result[:missing]
  end

  def test_all_three_required_subjects
    rule = '物理,化学,生物(3门科目考生均须选考方可报考)'
    assert_equal 'eligible', SubjectRequirements.classify(rule, SELECTED)[:status]
  end

  def test_politics_and_history_are_not_silently_allowed
    %w[思想政治 历史 地理].each do |subject|
      result = SubjectRequirements.classify("#{subject}(1门科目考生必须选考方可报考)", SELECTED)
      assert_equal 'ineligible', result[:status]
      assert_equal [subject], result[:missing]
    end
  end

  def test_mixed_requirement_reports_missing_history
    result = SubjectRequirements.classify('化学,历史(2门科目考生均须选考方可报考)', SELECTED)
    assert_equal ['历史'], result[:missing]
  end

  def test_unknown_blank_any_of_and_malformed_rules_require_review
    [nil, '', '不限', '物理,化学(任选一门)', '物理(2门科目考生均须选考方可报考)', '物理,物理(2门科目考生均须选考方可报考)', '心理(1门科目考生必须选考方可报考)'].each do |rule|
      assert_equal 'review_required', SubjectRequirements.classify(rule, SELECTED)[:status]
    end
  end

  def test_selected_subjects_follow_liaoning_three_plus_one_plus_two
    assert_equal SELECTED, SubjectRequirements.selected_subjects([])
    assert_raises(RuntimeError) { SubjectRequirements.selected_subjects(%w[物理 历史 化学]) }
    assert_raises(RuntimeError) { SubjectRequirements.selected_subjects(%w[化学 生物 地理]) }
    assert_raises(RuntimeError) { SubjectRequirements.selected_subjects(%w[物理 化学 化学]) }
  end
end