.PHONY: help public
help:
	@echo available rules:
	@echo make public - puts public content in public/

export BASE_URL = https://status.rapidcow.org/

public: $(patsubst %,public/%,.domains robots.txt index.html feed.html feed.xml)

public/robots.txt: robots.txt
	cp $< $@
public/.domains: .domains
	cp $< $@

# catch-all rule
public/%: % mkpub.pl data/*.dat
	@mkdir -p public/
	carmel exec perl mkpub.pl $< > $@
