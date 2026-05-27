.PHONY: help public
help:
	@echo available rules:
	@echo make public - puts public content in public/

export BASE_URL = https://status.rapidcow.org/

public: $(patsubst %,public/%,robots.txt index.html feed.html feed.xml)

public/.domains: .domains
	@mkdir -p public/
	cp $< $@
public/robots.txt: robots.txt
	@mkdir -p public/
	cp $< $@

PERL_EXEC ?= /usr/bin/env perl

# catch-all rule
public/%: % mkpub.pl data/*.dat
	@mkdir -p public/
	${PERL_EXEC} mkpub.pl $< > $@
