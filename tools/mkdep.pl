#!/usr/bin/perl
## --------------------------------------------------------------------------
##
##   Copyright 1996-2017 The NASM Authors - All Rights Reserved
##   See the file AUTHORS included with the NASM distribution for
##   the specific copyright holders.
##
##   Redistribution and use in source and binary forms, with or without
##   modification, are permitted provided that the following
##   conditions are met:
##
##   * Redistributions of source code must retain the above copyright
##     notice, this list of conditions and the following disclaimer.
##   * Redistributions in binary form must reproduce the above
##     copyright notice, this list of conditions and the following
##     disclaimer in the documentation and/or other materials provided
##     with the distribution.
##
##     THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND
##     CONTRIBUTORS "AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES,
##     INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF
##     MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
##     DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR
##     CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
##     SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT
##     NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
##     LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION)
##     HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
##     CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR
##     OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE,
##     EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
##
## --------------------------------------------------------------------------

#
# Script to create Makefile-style dependencies.
#
# Usage:
#   perl mkdep.pl [-s path-separator][-o obj-ext] dir... > deps
#   perl mkdep.pl [-i][-e][-m makefile]...[-M makefile... --] dir...
#

use File::Spec;
use File::Basename;
use File::Copy;
use File::Temp;
use Fcntl;

$barrier = "#-- Everything below is generated by mkdep.pl - do not edit --#\n";

# This converts from filenames to full pathnames for our dependencies
%dep_path = {};

#
# Scan files for dependencies
#
sub scandeps($) {
    my($file) = @_;
    my $line;
    my %xdeps;
    my %mdeps;

    open(my $fh, '<', $file)
	or return;		# If not openable, assume generated

    while ( defined($line = <$fh>) ) {
	chomp $line;
	$line =~ s:/\*.*\*/::g;
	$line =~ s://.*$::;
	if ( $line =~ /^\s*\#\s*include\s+\"(.*)\"\s*$/ ) {
	    my $nf = $1;
	    if (!defined($dep_path{$nf})) {
		die "$0: cannot determine path for dependency: $file -> $nf\n";
	    }
	    $nf = $dep_path{$nf};
	    $mdeps{$nf}++;
	    $xdeps{$nf}++ unless ( defined($deps{$nf}) );
	}
    }
    close($fh);
    $deps{$file} = [keys(%mdeps)];

    foreach my $xf ( keys(%xdeps) ) {
	scandeps($xf);
    }
}

# %deps contains direct dependencies.  This subroutine resolves
# indirect dependencies that result.
sub alldeps($$) {
    my($file, $level) = @_;
    my %adeps;

    foreach my $dep ( @{$deps{$file}} ) {
	$adeps{$dep} = 1;
	foreach my $idep ( alldeps($dep, $level+1) ) {
	    $adeps{$idep} = 1;
	}
    }
    return sort(keys(%adeps));
}

# This converts a filename from host syntax to target syntax
# This almost certainly works only on relative filenames...
sub convert_file($$) {
    my($file,$sep) = @_;

    my @fspec = (basename($file));
    while ( ($file = dirname($file)) ne File::Spec->curdir() &&
	    $file ne File::Spec->rootdir() ) {
	unshift(@fspec, basename($file));
    }

    if ( $sep eq '' ) {
	# This means kill path completely.  Used with Makes who do
	# path searches, but doesn't handle output files in subdirectories,
	# like OpenWatcom WMAKE.
	return $fspec[scalar(@fspec)-1];
    } else {
	return join($sep, @fspec);
    }
}

#
# Insert dependencies into a Makefile
#
sub _insert_deps($$) {
    my($file, $out) = @_;

    open(my $in, '<', $file)
	or die "$0: Cannot open input: $file\n";

    my $line, $parm, $val;
    my $obj = '.o';		# Defaults
    my $sep = '/';
    my $cont = "\\";
    my $include_command = undef;
    my $selfrule = 0;
    my $do_external = 0;
    my $maxline = 78;		# Seems like a reasonable default
    my @exclude = ();		# Don't exclude anything
    my @genhdrs = ();
    my $external = undef;
    my $raw_output = 0;
    my @outfile = ();
    my $done = 0;

    while ( defined($line = <$in>) && !$done ) {
	if ( $line =~ /^([^\s\#\$\:]+\.h):/ ) {
	    # Note: we trust the first Makefile given best
	    my $fpath = $1;
	    my $fbase = basename($fpath);
	    if (!defined($dep_path{$fbase})) {
		$dep_path{$fbase} = $fpath;
		print STDERR "Makefile: $fbase -> $fpath\n";
	    }
	} elsif ( $line =~ /^\s*\#\s*@([a-z0-9-]+):\s*\"([^\"]*)\"/ ) {
	    $parm = $1;  $val = $2;
	    if ( $parm eq 'object-ending' ) {
		$obj = $val;
	    } elsif ( $parm eq 'path-separator' ) {
		$sep = $val;
	    } elsif ( $parm eq 'line-width' ) {
		$maxline = $val+0;
	    } elsif ( $parm eq 'continuation' ) {
		$cont = $val;
	    } elsif ( $parm eq 'exclude' ) {
		@exclude = split(/\,/, $val);
	    } elsif ( $parm eq 'include-command' ) {
		$include_command = $val;
	    } elsif ( $parm eq 'external' ) {
		# Keep dependencies in an external file
		$external = $val;
	    } elsif ( $parm eq 'selfrule' ) {
		$selfrule = !!$val;
	    }
	} elsif ( $line =~ /^(\s*\#?\s*EXTERNAL_DEPENDENCIES\s*=\s*)([01])\s*$/ ) {
	    $is_external = $externalize ? 1 : $force_inline ? 0 : $2+0;
	    $line = $1.$is_external."\n";
	} elsif ( $line eq $barrier ) {
	    $done = 1;		# Stop reading input at barrier line
	}

	push @outfile, $line;
    }
    close($in);

    $is_external = $is_external && defined($external);

    if ( !$is_external || $externalize ) {
	print $out @outfile;
    } else {
	print $out $barrier;	# Start generated file with barrier
    }

    if ( $externalize ) {
	if ( $is_external && defined($include_command) ) {
	    print $out "$include_command $external\n";
	}
	return undef;
    }

    my $e;
    my %do_exclude = ();
    foreach $e (@exclude) {
	$do_exclude{$e} = 1;
    }

    foreach my $dfile ($external, sort(keys(%deps)) ) {
	my $ofile;
	my @deps;

	if ( $selfrule && $dfile eq $external ) {
	    $ofile = convert_file($dfile, $sep).':';
	    @deps = sort(keys(%deps));
	} elsif ( $dfile =~ /^(.*)\.[Cc]$/ ) {
	    $ofile = convert_file($1, $sep).$obj.':';
	    @deps = ($dfile,alldeps($dfile,1));
	}

	if (defined($ofile)) {
	    my $len = length($ofile);
	    print $out $ofile;
	    foreach my $dep (@deps) {
		unless ($do_exclude{$dep}) {
		    my $str = convert_file($dep, $sep);
		    my $sl = length($str)+1;
		    if ( $len+$sl > $maxline-2 ) {
			print $out ' ', $cont, "\n ", $str;
			$len = $sl;
		    } else {
			print $out ' ', $str;
			$len += $sl;
		    }
		}
	    }
	    print $out "\n";
	}
    }

    return $external;
}

sub insert_deps($)
{
    my($mkfile) = @_;
    my $tmp = File::Temp->new(DIR => dirname($mkfile));
    my $tmpname = $tmp->filename;

    my $newname = _insert_deps($mkfile, $tmp);
    close($tmp);

    $newname = $mkfile unless(defined($newname));

    move($tmpname, $newname);
}

#
# Main program
#

my %deps = ();
my @files = ();
my @mkfiles = ();
my $mkmode = 0;
$force_inline = 0;
$externalize = 0;
$debug = 0;

while ( defined(my $arg = shift(@ARGV)) ) {
    if ( $arg eq '-m' ) {
	$arg = shift(@ARGV);
	push(@mkfiles, $arg);
    } elsif ( $arg eq '-i' ) {
	$force_inline = 1;
    } elsif ( $arg eq '-e' ) {
	$externalize = 1;
    } elsif ( $arg eq '-d' ) {
	$debug++;
    } elsif ( $arg eq '-M' ) {
	$mkmode = 1;		# Futher filenames are output Makefile names
    } elsif ( $arg eq '--' && $mkmode ) {
	$mkmode = 0;
    } elsif ( $arg =~ /^-/ ) {
	die "Unknown option: $arg\n";
    } else {
	if ( $mkmode ) {
	    push(@mkfiles, $arg);
	} else {
	    push(@files, $arg);
	}
    }
}

my @cfiles = ();

foreach my $dir ( @files ) {
    opendir(DIR, $dir) or die "$0: Cannot open directory: $dir";

    while ( my $file = readdir(DIR) ) {
	$path = ($dir eq File::Spec->curdir())
	    ? $file : File::Spec->catfile($dir,$file);
	if ( $file =~ /\.[Cc]$/ ) {
	    push(@cfiles, $path);
	} elsif ( $file =~ /\.[Hh]$/ ) {
	    print STDERR "Filesystem: $file -> $path\n" if ( $debug );
	    $dep_path{$file} = $path; # Allow the blank filename
	    $dep_path{$path} = $path; # Also allow the full pathname
	}
    }
    closedir(DIR);
}

foreach my $cfile ( @cfiles ) {
    scandeps($cfile);
}

foreach my $mkfile ( @mkfiles ) {
    insert_deps($mkfile);
}
