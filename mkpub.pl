#!/usr/bin/env perl

use strict;
use warnings;
use Template;
# perl null coalescence ftw ^^!!!
# we can use v5.10 proudly
# https://stackoverflow.com/a/1891986
use v5.10;

# global constant???
my $DEFAULT_BASE_URL = 'https://status.rapidcow.org/';
my $BASE_URL = $ENV{BASE_URL} // $DEFAULT_BASE_URL;

# parse gets the header; get_body gets the rest
sub parse {
	my $message = shift;
	die unless defined $message;
	my %headers;
	for my $line (split "\n", $message) {
		last unless length $line;
		my @fields = split ": ", $line, 2;
		die "not enough fields: $line\n" if @fields < 2;
		my ($field, $value) = @fields;
		# turn RFC style header (Content-Location) into
		# C-esque variable names (content_location)
		my $fieldname = $field;
		$fieldname =~ s/-/_/g;
		$fieldname = lc $fieldname;
		if (exists $headers{$fieldname}) {
			die "duplicate field: $field\n";
		}
		$headers{$fieldname} = $value;
	}
	return \%headers;
}

sub get_body {
	my $message = shift;
	die unless defined $message;
	my @body;
	my $head = 1;
	for my $line (split "\n", $message) {
		if ($head) {
			$head = length $line;
		} else {
			push @body, $line;
		}
	}
	return join "\n", @body;
}

# fetch feed items from data/
sub ls_items {
	my @items;
	for my $file (reverse sort glob "data/*.dat") {
		my $name = $file =~ s{^data/|[.]dat$}{}gr;
		my %item;
		my $message;
		my $template = Template->new({
			INCLUDE_PATH => ['.'],
		}) || die $Template::ERROR, "\n";
		# Note: initializing $message is necessary
		# because TT actually appends to it
		$message = '';
		$template->process($file, {
			html => 0,
		}, \$message) || die $template->error(), "\n";
		$item{headers} = parse $message;
		$item{headers}{content_location}
			= ($ENV{BASE_URL} // $DEFAULT_BASE_URL)
			. "feed.html#$name";
		$item{content}{text} = get_body $message;
		$message = '';
		$template->process($file, {
			html => 1,
		}, \$message) || die $template->error(), "\n";
		$item{content}{html} = get_body $message;
		$item{name} = $name;
		# IMPORTANT: perl hashes are, deep down, an array,
		# so if we push %item itself, the key-value would
		# be pushed as if they are separate items.
		push @items, \%item;
	}
	return \@items;
}

# convert C-esque case into RFC822 case (this is
# too complicated to do in TT without resorting to
# basically perl code, so might as well write a
# filter specifically for this)
sub rfc822_case {
	my $text = shift;
	my @words = split '_', $text;
	my @Words = map { $_ eq 'id' ? 'ID' : ucfirst $_ } @words;
	return join '-', @Words;
}

# likewise there isn't a strip trailing whitespace...
sub strip_trail {
	my $text = shift;
	# this time, respect trailing linefeed
	# when there is one.  the -1 makes sure that
	# something that looks like "A\nB\n" becomes
	# [ "A", "B", "" ], so that the last "line" does
	# not get lost when we join the lines back
	my @lines = split "\n", $text, -1;
	s/[ \t]+$// for @lines;
	return join "\n", @lines;
}

# this is specifically for a more-or-less recent post...
sub dedent_comment {
	my $text = shift;
	my $prefix = ' ' x 2;
	my @lines = split "\n", $text, -1;
	# are we in a comment?
	my $incmt = 0;
	for (@lines) {
		# using $_ is the only way to justify my sadness
		# for the removal of given/when.... :<
		if ($_ eq '<!--') {
			s/^[ ]{,2}//;
			$incmt = 1;
		} elsif ($_ eq '-->') {
			s/^[ ]{,2}//;
			$incmt = 0;
		} elsif ($_) {
			s/^[ ]{,2}//;
		}
	}
	return join "\n", @lines;
}

# main function
my $file = shift;
die "usage: $0 <file>\n" unless defined $file;

my $template = Template->new({
	INCLUDE_PATH => ['.'],
	FILTERS => {
		rfc822_case => \&rfc822_case,
		strip_trail => \&strip_trail,
		dedent_comment => \&dedent_comment,
	},
}) || die $Template::ERROR, "\n";
$template->process($file, {
	items => ls_items(),
	BASE_URL => $BASE_URL,
}) || die $template->error(), "\n";
