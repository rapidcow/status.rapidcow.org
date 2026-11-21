#!/usr/bin/env perl

use 5.010;
use strict;
use warnings;

use Data::Dumper;
use Fcntl qw(:seek);
use IPC::Open2;

use constant DEBUG => 0;

my %REPLACE;
my %futures;
my %parents;

# Identity rewrite: webmaster@rapidcow.org => rapidcow@HOST.
#
# The T480s got Linux between the afternoon of 2024-12-04 and the
# morning of 2024-12-05 (US/Central).  Before that, everything made
# under webmaster@ came from the MacBook Pro; after it, from the T480s.
# No commit in any of the site repositories falls inside that window,
# so any instant in it (this one is 2024-12-05 00:00 -0600) gives the
# same answer.
#
# author and committer are judged separately, each by its own
# timestamp, and each keeps its own timestamp and zone.
#
# %MBP_LATE lists the exceptions: commits made on the MacBook after
# the cutoff (from the MacBook's own HEAD reflog), keyed by the full
# hash of the ORIGINAL commit.
use constant OLD_EMAIL => 'webmaster@rapidcow.org';
use constant CUTOFF    => 1733378400;
use constant HOST_MBP  => 'RCs-MacBook-Pro.local';
use constant HOST_T480S => 'RCs-T480s.local';
my %MBP_LATE = map { (split)[0] => 1 } split /^/, <<MBP_LATE;
MBP_LATE

$/ = "\012";
$Data::Dumper::Useqq = 1;

sub hash
{
	local ($., $!);
	my ($type, @content) = @_;
	my ($rdr, $wtr);
	if ($] < 5.006) {
		require Symbol;
		$rdr = Symbol::gensym();
		$wtr = Symbol::gensym();
	}
	my $pid = open2($rdr, $wtr, qw(git hash-object -t), $type, qw(-w --stdin));
	print { $wtr } @content or warn "hash-object: write pipe: $!\n";
	close $wtr or warn "hash-object: close pipe: $!\n";
	my $hash = <$rdr>;
	waitpid $pid, 0;
	$? == 0 or die "hash-object: died: wstat $? (code @{[$? >> 8]})\n";
	defined $hash or die "BUG: hash-object returned nothing";
	chomp $hash;
	return $hash,
}

foreach my $this (`git rev-list --all`) {
	chomp $this;
	my @parents;
	foreach (`git cat-file commit $this`) {
		next if /^ /;
		if (s/^parent //) {
			chomp;
			push @parents, $_;
		}
		last if /^$/;
	}
	foreach my $past (@parents) {
		push @{$futures{$past}}, $this;
		push @{$parents{$this}}, $past;
	}
}

my %refs = map { chomp; split } split /^/, <<MAP;
c4b08190ee3500bf268dc0d75a619de3dfefb782 refs/heads/0
MAP
# Annotated tags are their own object (tagger/message/etc.) pointing
# at a commit via an "object" header, unlike branches and lightweight
# tags where the ref sha IS the commit sha.  `git cat-file commit`
# auto-dereferences tag objects, so if we naively ran the rewrite walk
# on a tag's own sha it would silently peel it down to the commit it
# points to and the tag object would just vanish.  Record which shas
# are tag objects, and which commit the walk should actually rewrite
# on their behalf, so we can reconstruct a proper tag object after
# (see rewrite_tag).
my (%is_tag, %peel);
foreach my $sha (keys %refs) {
	chomp(my $type = `git cat-file -t $sha`);
	if ($type eq 'tag') {
		$is_tag{$sha} = 1;
		chomp($peel{$sha} = `git rev-parse $sha^{commit}`);
	}
	else {
		$peel{$sha} = $sha;
	}
}
# A commit that mentions another commit by its full hash has to be
# rewritten after it, or the mention would keep the old hash (this
# can happen across branches, where neither is the other's ancestor).
# Treat each mention as one more edge next to the parent edges.
my %deps = map { $_ => [ @{$parents{$_}} ] } keys %parents;
{
	local $/ = "\0";
	my %mentions;
	foreach (`git log --all --format=%H%n%B%x00`) {
		chomp;
		s/\A\s+//;
		next unless length;
		my ($sha, $body) = split /\n/, $_, 2;
		$mentions{$sha} = $body // '';
	}
	foreach my $sha (sort keys %mentions) {
		my %seen;
		foreach (lc($mentions{$sha}) =~ /\b([0-9a-f]{40})\b/g) {
			next if $_ eq $sha || $seen{$_}++ || !exists $mentions{$_};
			push @{$deps{$sha}}, $_;
		}
	}
}
# Reverse topological sort
my @walk = reachable(\%deps, values %peel);

#
# Non-recursive version of:
#
# L ← Empty list that will contain the sorted nodes
# while exists nodes without a permanent mark do
#     select an unmarked node n
#     visit(n)
#
# function visit(node n)
#     if n has a permanent mark then
#         return
#     if n has a temporary mark then
#         stop   (graph has at least one cycle)
#
#     mark n with a temporary mark
#
#     for each node m with an edge from n to m do
#         visit(m)
#
#     mark n with a permanent mark
#     add n to head of L
#
# /* from https://en.wikipedia.org/wiki/Topological_sorting#Depth-first_search */
sub reachable
{
	my ($graph, @node) = @_;
	my (%count, @list);
	my (@paths, @stop);
	# Stack trace
	@paths = ([]) x @node;
	# Bunch of sentinels
	@stop = (!!0) x @node;
	while (@node) {
		my $node = pop @node;
		my $path = pop @paths;
		my $stop = pop @stop;
		my $count = \$count{$node};

		# @@@ corresponds to bottom half of visit()
		if ($stop) {
			# We've visited all children; STOP and return.
			push @list, $node;
			$$count = 2;
			next;
		}
		# @@@ corresponds to top half of visit()
		$$count ||= 0;
		if ($$count == 2) {
			# Ok?  So $node has been emitted.  No biggie,
			# though it would be unwise to walk this again.
			next;
		}
		if ($$count == 1) {
			# Once of the children from $node led us all
			# the way back to it; there is a cycle in the
			# graph and it cannot be topologically sorted.
			my @path;
			foreach (reverse @$path) {
				push @path, $_;
				last if $_ eq $node;
			}
			die "Cyclic graph eats its own tail at ",
			join ' => ', reverse $node, @path;
		}
		# $count is nil; this is a fresh node
		{
			# Make sure whoever gets here GETS it.  It'd
			# take a while anyways; the children would have
			# all been emitted in the next part of the stack.
			push @node, $node;
			push @paths, $path;
			push @stop, !!1;

			my @path = (@$path, $node);
			foreach (@{$graph->{$node} // []}) {
				push @node, $_;
				push @paths, \@path;
				push @stop, !!0;
			}
		}
	}
	@list;
}

# Maintain nodes in the current graph and the rebased graph
my ($this, $that);
my ($past, $last);

my $i = 1; foreach (@walk) {
	$this = $_;
	$that = $REPLACE{$this} // $this;
	print STDERR "WALK $_ ($i of @{[0+@walk]})\r" if -t STDERR;

	open my $tempfh, '+>', \(my $mem = "") or die "<:memory: error: $!";
	print { $tempfh } `git cat-file commit $that`;

	foreach my $role (qw(author committer)) {
		my (undef, $email, $when, $zone) = get_identity($tempfh, $role);
		next unless defined $email && $email eq OLD_EMAIL;
		my $host = ($MBP_LATE{$this} || $when < CUTOFF)
			? HOST_MBP : HOST_T480S;
		replace_header($tempfh, \$mem, $role,
			"$role Ethan Meng <rapidcow\@$host> $when $zone");
	}

	foreach my $past (@{$parents{$this} // []}) {
		if (($last = $REPLACE{$past} // $past) ne $past) {
			replace_header($tempfh, \$mem, "parent $past", "parent $last");
		}
	}

	my $content = get_all_content($tempfh);
	# Most contents remain untouched, so probably
	# do the check first to avoid pipe overhead...
	my $newbody = $content;
	# %REPLACE at the current instant should be just
	# right.  (If a commit was ever able to mention a
	# "future" commit, well.... let's just say, it
	# wouldn't be our job to panic over anyways. :x)
	while (my ($SK, $SV) = each %REPLACE) {
		$newbody =~ s/\Q$SK\E/$SV/ig;
	}
	unless ($newbody eq $content) {
		replace_content($tempfh, \$mem, $newbody);
	}

	seek $tempfh, 0, SEEK_SET;
	$that = hash commit => <$tempfh>;
	$REPLACE{$this} = $that;
} continue {
	$i += 1;
}
print STDERR "\n" if -t STDERR;

# Now that every commit has been rewritten, rebuild the annotated tag
# objects so they keep pointing at a tag (with their original tagger
# and message intact) instead of getting peeled down to a bare commit.
foreach my $sha (keys %refs) {
	rewrite_tag($sha) if $is_tag{$sha};
}

foreach (sort keys %REPLACE) {
	my ($this, $that) = ($_, $REPLACE{$_});
	if ($this ne $that) {
		print "REPLACE $this WITH $that\n";
	}
}
my @refs = sort {
	$a->[1] cmp $b->[1]
	|| $a->[0] cmp $b->[0]
} map [ $_ => $refs{$_} ], keys %refs;
foreach my $refv (@refs) {
	my ($sha, $ref) = @$refv;
	print $REPLACE{$sha}, " ", $ref, "\n";
}

sub replace_header
{
	local $.;
	my ($tempfh, $memptr, $spec, $line) = @_;
	chomp $line;
	seek $tempfh, 0, SEEK_SET;
	my @buffer;
	# Reset the input line counter.  Note that
	# simply unsetting $. is useless.
	$. = 0;
	while (<$tempfh>) {
		chomp (my $canon_line = $_);
		if (1 .. /^$/) {
			# If there is a space, consider it a full-line match.
			if ($spec =~ / /) {
				next unless $canon_line eq $spec;
			}
			else {
				# Must be a field name (and not any prefix!)
				next unless /\A\Q$spec\E ?/;
			}
			$_ = "$line$/";
		}
	}
	continue {
		push @buffer, $_;
	}
	$$memptr = '';
	seek $tempfh, 0, SEEK_SET;
	print { $tempfh } $_ for @buffer;
}

sub replace_content
{
	local $.;
	my ($tempfh, $memptr, @content) = @_;
	seek $tempfh, 0, SEEK_SET;
	my @buffer;
	$. = 0;
	while (<$tempfh>) {
		last unless 1 .. /^$/;
	}
	continue {
		push @buffer, $_;
	}
	push @buffer, @content;
	seek $tempfh, 0, SEEK_SET;
	$$memptr = '';
	print { $tempfh } $_ for @buffer;
}

sub get_all_content
{
	local $.;
	local $/ = $/;
	my ($tempfh) = @_;
	seek $tempfh, 0, SEEK_SET;
	$. = 0;
	my $content = '';
	while (<$tempfh>) {
		unless (1 .. /^$/) {
			$content .= $_;
			last;
		}
	}
	undef $/;
	my $morecontent = <$tempfh>;
	$content .= $morecontent if defined $morecontent;
	return $content;
}

sub rewrite_tag
{
	my ($sha) = @_;
	return $REPLACE{$sha} if exists $REPLACE{$sha};
	my @lines = `git cat-file tag $sha`;
	$lines[0] =~ /^object ([0-9a-f]{40})\n\z/
		or die "tag $sha: malformed object header: $lines[0]";
	my $old = $1;
	my $new = $REPLACE{$old};
	unless (defined $new) {
		# The tag points at another tag (or at something that
		# never showed up in the commit walk); recurse/fall back.
		chomp(my $type = `git cat-file -t $old`);
		$new = $type eq 'tag' ? rewrite_tag($old) : $old;
	}
	$lines[0] = "object $new\n";
	return $REPLACE{$sha} = hash tag => @lines;
}

sub get_committer_date
{
	local $.;
	local $/ = $/;
	my ($tempfh) = @_;
	seek $tempfh, 0, SEEK_SET;
	$. = 0;
	while (<$tempfh>) {
		last unless 1 .. /^$/;
		if (/^committer .+ <.*> ([0-9]+)/) {
			return $1;
		}
	}
	die "no committer date???";
}

sub get_identity
{
	local $.;
	local $/ = $/;
	my ($tempfh, $role) = @_;
	seek $tempfh, 0, SEEK_SET;
	$. = 0;
	while (<$tempfh>) {
		last unless 1 .. /^$/;
		if (/^\Q$role\E (.*) <(.*)> ([0-9]+) ([+-][0-9]{4})$/) {
			return ($1, $2, $3, $4);
		}
	}
	return;
}
