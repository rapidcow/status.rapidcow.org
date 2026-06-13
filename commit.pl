#!/usr/bin/env perl

# 5.12 for correct readdir behavior
use v5.14;
use strict;
use warnings;
use Git;
# error handling????
use Error qw(:try);

use Cwd 'abs_path';
use File::Spec::Functions qw(catfile);
use Getopt::Long;

my $yes_to_everything;
my @mesg;

Getopt::Long::Configure(qw( gnu_compat ));
GetOptions(
	'y' => \$yes_to_everything,
	'm=s@' => \@mesg,
) or die "usage: $0 [-y] [-m MESG ...]";

# $1: git repository
# $2: branch
# $3: tree-ish
sub commit {
	my $git = shift;
	my $head = shift;
	my $tree = shift;
	die unless defined $git;
	die unless defined $head;
	die unless defined $tree;
	my $parent;
	try {
		$parent = $git->command_oneline('rev-parse', '--verify', $head);
	} catch Error::Simple with {
		$parent = 0;
	};
THING: {
	say STDERR "# committing tree $tree";
	if ($parent) {
		say STDERR "# basing on $parent" if $parent;
		if ($yes_to_everything) {
			next THING;
		}
		print STDERR "# do you want to see a diff? (y/N) ";
		chomp (my $answer = <STDIN>);
		if ($answer eq 'y') {
			try {
				$git->command_noisy('diff', $parent, $tree);
			} catch Error::Simple with {
				# git-diff returns >0 status if any diff was
				# present at all; it's not really of use
			};
		}
	} else {
		say STDERR "# (root commit)";
	}
}
	if (!@mesg) {
		say STDERR "# please tell git-commit-tree about your commit message:";
		return $parent
			? $git->command_oneline('commit-tree', $tree, '-p', $parent)
			: $git->command_oneline('commit-tree', $tree);
	}
	else {
		chomp @mesg;
		$git->command_oneline('commit-tree',
			map ({ ('-m', $_) } @mesg),
			('-p', $parent) x !!$parent,
			$tree,
		);
	}
}

# $1: git repository
# $2: i am tired and it's literally just
# git hash-object -w $2
sub mkblob {
	my $git = shift;
	my $file = shift;
	die unless defined $git;
	die unless defined $file;
	return $git->command_oneline('hash-object', '-w', '-t', 'blob', $file);
}

# $1: Git repository
# $2: directory to commit
sub mktree {
	my $git = shift;
	my $dir = shift;
	die unless defined $git;
	die unless defined $dir;
	opendir my $dh, $dir or die "$!: $dir";
	my ($pid, $pipe_in, $pipe_out, $ctx)
		= $git->command_bidi_pipe('mktree');
	while (my $file = readdir $dh) {
		next if $file eq '.' || $file eq '..';
		my ($mode, $type, $name);
		if (-f $file) {
			$mode = '100644';
			$type = 'blob';
			$name = &mkblob ($git, catfile ($dir, $file));
		} elsif (-d $file) {
			$mode = '100755';
			$type = 'tree';
			$name = &mktree ($git, catfile ($dir, $file));
		} else {
			die "what is this lol: " . catfile ($dir, $file);
		}
		printf $pipe_out "%s %s %s\t%s\n", $mode, $type, $name, $file;
	}
	close $pipe_out;
	chomp (my $tree = <$pipe_in>);
	$git->command_close_bidi_pipe($pid, $pipe_in, undef, $ctx);
	closedir $dh;
	return $tree;
}

sub spawn {
	say STDERR "@_";
	system @_;
	my $status = $? >> 8;
	die ">0 status: $status" if $?;
}

spawn ('rm -rf public');
spawn ('make public');

my $git = Git->repository(
	WorkingCopy => abs_path('.'),
);
my $head = 'refs/heads/pages';
my $rev = commit $git, $head, mktree $git, 'public';
$git->command_noisy('update-ref', '-m', "($0) commit public", $head, $rev);
