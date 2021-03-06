require "test/unit"
require 'tempfile'

class TTest < Test::Unit::TestCase
  def test_one
    inputs = <<EOF
Aqu1.200001 Aqu1.200001 100.00  294 0 0 1 294 1 294 2e-166   583
Aqu1.200001 Aqu1.200002 100.00  74  0 0 221 294 237 164 5e-35  147
Aqu1.200001 Aqu1.200002 98.00 74  0 223 230 294 237 164 5e-35  147
Aqu1.200002 Aqu1.200002 100.00  237 0 0 1 237 1 237 2e-132   470
Aqu1.200002 Aqu1.200001 100.00  74  0 0 164 237 294 221 4e-35  147
Aqu1.200003 Aqu1.200003 100.00  189 0 0 1 189 1 189 7e-104   375
Aqu1.200003 Aqu1.206177 99.47 189 1 0 1 189 1 189 2e-101   367
Aqu1.200003 Aqu1.204378 98.94 188 2 0 1 188 1 188 2e-98  357
Aqu1.200003 Aqu1.219366 97.88 189 4 0 1 189 1 189 3e-94  343
EOF
    expected = <<EOF
Aqu1.200001 Aqu1.200002 100.00  74  0 0 221 294 237 164 5e-35  147
Aqu1.200001 Aqu1.200002 98.00 74  0 223 230 294 237 164 5e-35  147
Aqu1.200003 Aqu1.206177 99.47 189 1 0 1 189 1 189 2e-101   367
Aqu1.200003 Aqu1.204378 98.94 188 2 0 1 188 1 188 2e-98  357
Aqu1.200003 Aqu1.219366 97.88 189 4 0 1 189 1 189 3e-94  343
EOF
    
    Tempfile.open('meh') do |tempfile|
      tempfile.puts expected
      tempfile.close
      
      Tempfile.open('meh2') do |tempfile2|
        `blast_triangularise.rb #{tempfile.path} >#{tempfile2.path}`
        assert_equal expected, File.open(tempfile2.path,'r').read
      end
    end
  end
end