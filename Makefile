RSCRIPT = Rscript

.PHONY: all fetch data qa test lint clean

all: fetch data qa test

fetch:
	$(RSCRIPT) scripts/00_fetch.R

data:
	$(RSCRIPT) scripts/01_build_db.R

qa:
	$(RSCRIPT) scripts/02_qa_report.R

test:
	$(RSCRIPT) -e 'out <- testthat::test_dir("tests/testthat", stop_on_failure = TRUE)'

lint:
	$(RSCRIPT) -e 'res <- lintr::lint_dir("."); print(res); if (length(res) > 0) quit(status = 1)'

clean:
	rm -f data/db/*.duckdb data/db/*.duckdb.wal
