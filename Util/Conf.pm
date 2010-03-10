# Configuration reading and holding.

package Util::Conf;

use strict;
use Exporter;
use Carp qw(croak);

use vars qw(@ISA @EXPORT);
@ISA    = qw(Exporter);
@EXPORT = qw( get_names_by_type
              get_items_by_name
            );

sub SCALAR   () { 0x01 }
sub LIST     () { 0x02 }
sub REQUIRED () { 0x04 }

my $conf_file = "./ircxom.conf";

my %define =
  ( irc =>
    { name    => SCALAR | REQUIRED,
      server  => LIST   | REQUIRED,
      nick    => SCALAR | REQUIRED,
      uname   => SCALAR | REQUIRED,
      iname   => SCALAR | REQUIRED,
      away    => SCALAR | REQUIRED,
      flags   => SCALAR,
      quit    => SCALAR | REQUIRED,
      cuinfo  => SCALAR | REQUIRED,
      cver    => SCALAR | REQUIRED,
      ccinfo  => SCALAR | REQUIRED,
      channel => LIST   | REQUIRED,
      open    => SCALAR,
    },
    paths =>
    { data    => SCALAR | REQUIRED,
      url     => SCALAR | REQUIRED,
    },
  );

my ($section, $section_line, %item, %config);

sub flush_section {
  if (defined $section) {

    foreach my $item_name (sort keys %{$define{$section}}) {
      my $item_type = $define{$section}->{$item_name};

      if ($item_type & REQUIRED) {
        die "$section section needs a(n) $item_name item at $section_line\n"
          unless exists $item{$item_name};
      }
    }

    die "$section section $item{name} is redefined at $section_line\n"
      if exists $config{$item{name}};

    my $name = delete $item{name};
    $config{$name} = { %item, _type => $section };
  }
}

open(MPH, "<$conf_file") or die $!;
while (<MPH>) {
  chomp;
  s/\s*\#.*$//;
  next if /^\s*$/;

  # Section item.
  if (/^\s+(\S+)\s+(.*?)\s*$/) {

    die "item outside a section at $conf_file line $.\n"
      unless defined $section;

    die "unknown $section item at $conf_file line $.\n"
      unless exists $define{$section}->{$1};

    if (exists $item{$1}) {
      if (ref($item{$1}) eq 'ARRAY') {
        push @{$item{$1}}, $2;
      }
      else {
        die "option $1 redefined at $conf_file line $.\n";
      }
    }
    else {
      if ($define{$section}->{$1} & LIST) {
        $item{$1} = [ $2 ];
      }
      else {
        $item{$1} = $2;
      }
    }
    next;
  }

  # Section leader.
  if (/^(\S+)\s*$/) {

    # A new section ends the previous one.
    &flush_section();

    $section      = $1;
    $section_line = $.;
    undef %item;
    next;
  }

  die "syntax error in $conf_file at line $.\n";
}

&flush_section();

close MPH;

sub get_names_by_type {
  my $type = shift;
  my @names;

  while (my ($name, $item) = each %config) {
    next unless $item->{_type} eq $type;
    push @names, $name;
  }

  return @names if @names;
  croak "no configuration type matching \"$type\"";
}

sub get_items_by_name {
  my $name = shift;
  return () unless exists $config{$name};
  return %{$config{$name}};
}

1;
