#!/usr/bin/env perl

use strict;
use warnings;
# perl null coalescence ftw ^^!!!
# we can use v5.10 proudly
# https://stackoverflow.com/a/1891986
use v5.10;

use File::Basename qw( basename );
use File::Spec;
use RdKw::WwW::GenLib qw( parse_base locate );
use RdKw::WwW::GenGenLib 0.0002 qw(
	read_deps load_state
	norm_dep subs_dep uproot );
use Template;
use Time::Piece;

# global constant???
my $DEFAULT_SITE = 'https://status.rapidcow.org/';
my $BASE_URL = $ENV{BASE_URL} // '/';
my $SITE_URL = $ENV{SITE_URL} // $DEFAULT_SITE;

my $O = { base_url => $BASE_URL, site_url => $SITE_URL,
	rewrite_url => $ENV{REWRITE_URL} };
parse_base($O);
$BASE_URL = $O->{base_url};
$SITE_URL = $O->{site_url};

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
		# to preserve header order...
		push @{$headers{order}}, $fieldname;
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

# the page being built; locate() in entries is relative to it
my $target;

# read a feed item from FILE (feed/YEAR/DATE.dat)
sub load_item {
	my $file = shift;
	my $name = $file =~ s{.*/|[.]dat$}{}gr;
	my ($year) = $file =~ m{(?:\A|/)feed/(\d{4})/[^/]+\z}
		or die "$file: not in feed/YEAR/\n";
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
		locate => sub { locate($O, $target, @_); },
	}, \$message) || die $template->error(), "\n";
	$item{headers} = parse $message;
	# where the entry page lives (relative to the site root)
	$item{path} = "feed/$year/$name.html";
	$item{headers}{content_location}
		= $SITE_URL . $BASE_URL . $item{path};
	$item{content}{text} = get_body $message;
	$message = '';
	$template->process($file, {
		html => 1,
		locate => sub { locate($O, $target, @_); },
	}, \$message) || die $template->error(), "\n";
	$item{content}{html} = get_body $message;
	$item{name} = $name;
	$item{year} = $year;
	return \%item;
}

# the years we have entries for, newest first
sub ls_years {
	my %year;
	for my $dir (glob "feed/[0-9][0-9][0-9][0-9]") {
		$year{basename $dir} = 1 if -d $dir;
	}
	return [ reverse sort keys %year ];
}

# fetch feed items from feed/ (of the given YEAR, if any), newest first
sub ls_items {
	my $year = shift;
	my @items;
	# the name (DATE) sorts by time; YEAR/ is only for tidiness
	for my $file (sort { basename($b) cmp basename($a) }
		glob "feed/" . ($year // "[0-9][0-9][0-9][0-9]") . "/*.dat")
	{
		# IMPORTANT: perl hashes are, deep down, an array,
		# so if we push %item itself, the key-value would
		# be pushed as if they are separate items.
		push @items, load_item($file);
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
		if (/<!--$/) {
			s/^[ ]{,2}//;
			$incmt = 1;
		} elsif (/-->$/) {
			s/^[ ]{,2}//;
			$incmt = 0;
		} elsif ($incmt) {
			s/^[ ]{,2}//;
		}
	}
	return join "\n", @lines;
}

# this is meant to extract the address of an RFC822
# From/To header. but since we're dealing with the
# painfully simple <webmaster@rapidcow.org>, we can
# get away with something stupid....
sub address {
	my $text = shift;
	my $i = (index($text, "<") + 1);
	my $j = (index($text, ">", $i) + 1 || length($text) + 1) - 1;
	return substr($text, $i, $j - $i);
}

# according to this... https://stackoverflow.com/a/62477582
# also see perldoc Template::Manual::Directives in FILTER
# for examples of dynamic filters work
sub rfc822_date_factory {
	my ($context, $timezone) = @_;
	$timezone = $timezone // "GMT";
	my $offset;
	# on top of RFC822 we can allow Temps Universel Coordonné and Undertale time
	# of course, modern emails aren't supposed to have either, as per the updated
	# RFC2822 and RFC5322... but that doesn't mean we can't have fun here >:)
	if ($timezone eq "GMT" || $timezone eq "UTC" || $timezone eq "UT") {
		$offset = 0;
	} else {
		if ($timezone =~ m/\A([+-])(\d\d)(\d\d)\Z/) {
			my $sign = $1 eq '+' ? 60 : -60;
			my $hour = $2;
			my $mint = $3;
			$offset = $sign * ($hour*60 + $mint*1);
		} else {
			die "invalid RFC(2)822 timezone: $timezone";
		}
	}
	return sub {
		my $time = shift;
		# now we can format time as if the clock was
		# dialed forward/backward by that much
		return Time::Piece->gmtime($time + $offset)->strftime(
			"%a, %d %b %Y %H:%M:%S $timezone"
		);
	}
}

sub rfc822_now {
	return Time::Piece->localtime()->strftime("%a, %d %b %Y %H:%M:%S %z");
}

# main function
my $file = shift;
# the name of the target, for when the source does not say
# (feed/YEAR/index.html is made from the one year.html,
# feed/YEAR.xml from feed.xml)
my $as = shift;
die "usage: $0 <file> [<target>]\n" unless defined $file;

($target = do {
	my %I = read_deps($file);
	my ($source, $have) = defined $I{HAVE}
		? ('HAVE', norm_dep($I{HAVE}))
		: ('file', File::Spec->canonpath($file));
	my $name;
	if (defined $I{HAVE} && defined ($name
		= uproot('${a}', $have)))
	{
		my $D = %{+{ load_state('.') }}{config};
		subs_dep($D, $name);
	}
	elsif (defined ($name = uproot('.', $have)))
	{
		$name;
	}
	else {
		die "$source `$have' not in source directory\n";
	}
}) =~ s/\A\/+//;
$target = $as if defined $as;

# feed/YEAR/DATE.dat is rendered with entry.html, as feed/YEAR/DATE.html
my ($entry, $year, @items);
my $years = ls_years();
if ($target =~ s/[.]dat\z/.html/) {
	$entry = load_item($file);
	$file = 'skel/entry.html';
} elsif ($target =~ m{\Afeed/(\d{4})/index[.]html\z}
	or $target =~ m{\Afeed/(\d{4})[.]xml\z})
{
	$year = $1;
	@items = @{ ls_items($year) };
} elsif ($target eq 'feed.xml') {
	# feed.xml has the recent entries, and says which they are:
	# they are what it NEEDs (see scripts/update-needs)
	my %I = read_deps($file);
	@items = map { load_item($_) } reverse sort { basename($a) cmp basename($b) }
		grep { m{\Afeed/\d{4}/[^/]+[.]dat\z} } @{ $I{NEED} || [] };
} else {
	@items = @{ ls_items() };
}
# feed.html only shows the latest year, and points at the others
my $latest = @$years ? $years->[0] : undef;
my @archives = map {
	my $y = $_;
	+{
		year => $y,
		path => "feed/$y/index.html",
		count => scalar(() = glob "feed/$y/*.dat"),
	}
} @$years[1 .. $#$years];

my $template = Template->new({
	INCLUDE_PATH => ['.'],
	# now to declare our filters according to
	# Template::Filters...
	FILTERS => {
		rfc822_case => \&rfc822_case,
		strip_trail => \&strip_trail,
		dedent_comment => \&dedent_comment,
		address => \&address,
		rfc822_date => [ \&rfc822_date_factory, 1 ],
	},
}) || die $Template::ERROR, "\n";
$template->process($file, {
	items => \@items,
	item => $entry,
	year => $year,
	latest => [ grep { $_->{year} eq $latest } @items ],
	archives => \@archives,
	BASE_URL => $BASE_URL,
	SITE_URL => $SITE_URL,
	rfc822_now => \&rfc822_now,
	locate => sub {
		my ($path) = @_;
		if ($O->{rewrite_url}) {
			$path =~ s{([^/]+)\.html\z}{$1 eq "index" ? "" : $1}e;
		}
		locate($O, $target, $path);
	},
}) || die $template->error(), "\n";
