#!/usr/bin/perl

# -n do not include custom_ scripts
# -v verbose mode, shows progress stuff

# this version of locles processes not only all required .pl files
# but also all parse_html_templated files.

use utf8;
use strict;

use Carp;
use Data::Dumper;
use English;
use File::Slurp qw(slurp);
use FileHandle;
use Getopt::Long;
use IO::Dir;
use List::Util qw(first);
use POSIX;
use Pod::Usage;

$OUTPUT_AUTOFLUSH = 1;

my $opt_v  = 0;
my $opt_n  = 0;
my $opt_c  = 0;
my $debug  = 0;

parse_args();

my $basedir      = "../..";
my $locales_dir  = ".";
my $bindir       = "$basedir/bin/mozilla";
my @progdirs     = ( "$basedir/SL" );
my $dbupdir      = "$basedir/sql/Pg-upgrade";
my $dbupdir2     = "$basedir/sql/Pg-upgrade2";
my $menufile     = "menu.ini";
my @javascript_dirs = ($basedir .'/js', $basedir .'/templates/webpages');
my $submitsearch = qr/type\s*=\s*[\"\']?submit/i;
our $self        = {};
our $missing     = {};
our @lost        = ();

my (%referenced_html_files, %locale, %htmllocale, %alllocales, %cached, %submit, %jslocale);
my ($ALL_HEADER, $MISSING_HEADER, $LOST_HEADER);

init();

sub find_files {
  my ($top_dir_name) = @_;

  my (@files, $finder);

  $finder = sub {
    my ($dir_name) = @_;

    tie my %dir_h, 'IO::Dir', $dir_name;

    push @files,   grep { -f } map { "${dir_name}/${_}" }                       keys %dir_h;
    my @sub_dirs = grep { -d } map { "${dir_name}/${_}" } grep { ! m/^\.\.?$/ } keys %dir_h;

    $finder->($_) for @sub_dirs;
  };

  $finder->($top_dir_name);

  return @files;
}

sub merge_texts {
# overwrite existing entries with the ones from 'missing'
  $self->{texts}->{$_} = $missing->{$_} for grep { $missing->{$_} } keys %alllocales;

  # try to set missing entries from lost ones
  my %lost_by_text = map { ($_->{text} => $_->{translation}) } @lost;
  $self->{texts}->{$_} = $lost_by_text{$_} for grep { !$self->{texts}{$_} } keys %alllocales;
}

my @bindir_files = find_files($bindir);
my @progfiles    = map { m:^(.+)/([^/]+)$:; [ $2, $1 ]  } grep { /\.pl$/ && !/_custom/ } @bindir_files;
my @customfiles  = grep /_custom/, @bindir_files;

push @progfiles, map { m:^(.+)/([^/]+)$:; [ $2, $1 ] } grep { /\.pm$/ } map { find_files($_) } @progdirs;

# put customized files into @customfiles
my (@menufiles, %dir_h);

if ($opt_n) {
  @customfiles = ();
  @menufiles   = ($menufile);
} else {
  tie %dir_h, 'IO::Dir', $basedir;
  @menufiles = map { "$basedir/$_" } grep { /.*?_$menufile$/ } keys %dir_h;
  unshift @menufiles, "$basedir/$menufile";
}

tie %dir_h, 'IO::Dir', $dbupdir;
my @dbplfiles = grep { /\.pl$/ } keys %dir_h;

tie %dir_h, 'IO::Dir', $dbupdir2;
my @dbplfiles2 = grep { /\.pl$/ } keys %dir_h;

# slurp the translations in
if (-f "$locales_dir/all") {
  require "$locales_dir/all";
}
if (-f "$locales_dir/missing") {
  require "$locales_dir/missing" ;
  unlink "$locales_dir/missing";
}
if (-f "$locales_dir/lost") {
  require "$locales_dir/lost";
  unlink "$locales_dir/lost";
}

my $charset = slurp("$locales_dir/charset") || 'utf-8';
chomp $charset;

my %old_texts = %{ $self->{texts} || {} };

handle_file(@{ $_ })       for @progfiles;
handle_file($_, $dbupdir)  for @dbplfiles;
handle_file($_, $dbupdir2) for @dbplfiles2;
scanmenu($_)               for @menufiles;

for my $file_name (map({find_files($_)} @javascript_dirs)) {
  scan_javascript_file($file_name);
}

# merge entries to translate with entries from files 'missing' and 'lost'
merge_texts();

# generate all
generate_file(
  file      => "$locales_dir/all",
  header    => $ALL_HEADER,
  data_name => '$self->{texts}',
  data_sub  => sub { _print_line($_, $self->{texts}{$_}, @_) for sort keys %alllocales },
);

open(my $js_file, '>:encoding(utf8)', $locales_dir .'/js.js') || die;
print $js_file '{'."\n";
my $first_entry = 1;
for my $key (sort(keys(%jslocale))) {
  print $js_file (!$first_entry ? ',' : '') . _double_quote($key) .':'. _double_quote($self->{texts}{$key}) ."\n";
  $first_entry = 0;
}
print $js_file '}'."\n";
close($js_file);

  foreach my $text (keys %$missing) {
    if ($locale{$text} || $htmllocale{$text}) {
      unless ($self->{texts}{$text}) {
        $self->{texts}{$text} = $missing->{$text};
      }
    }
  }


# calc and generate missing
my @new_missing = grep { !$self->{texts}{$_} } sort keys %alllocales;

if (@new_missing) {
  generate_file(
    file      => "$locales_dir/missing",
    header    => $MISSING_HEADER,
    data_name => '$missing',
    data_sub  => sub { _print_line($_, '', @_) for @new_missing },
  );
}

# calc and generate lost
while (my ($text, $translation) = each %old_texts) {
  next if ($alllocales{$text});
  push @lost, { 'text' => $text, 'translation' => $translation };
}

if (scalar @lost) {
  splice @lost, 0, (scalar @lost - 50) if (scalar @lost > 50);
  generate_file(
    file      => "$locales_dir/lost",
    header    => $LOST_HEADER,
    delim     => '()',
    data_name => '@lost',
    data_sub  => sub {
      _print_line($_->{text}, $_->{translation}, @_, template => "  { 'text' => %s, 'translation' => %s },\n") for @lost;
    },
  );
}

my $trlanguage = slurp("$locales_dir/LANGUAGE");
chomp $trlanguage;

search_unused_htmlfiles() if $opt_c;

my $count  = scalar keys %alllocales;
my $notext = scalar @new_missing;
my $per    = sprintf("%.1f", ($count - $notext) / $count * 100);
print "\n$trlanguage - ${per}%";
print " - $notext/$count missing" if $notext;
print "\n";

exit;

# eom

sub init {
  $ALL_HEADER = <<EOL;
# These are all the texts to build the translations files.
# The file has the form of 'english text'  => 'foreign text',
# you can add the translation in this file or in the 'missing' file
# run locales.pl from this directory to rebuild the translation files
EOL
  $MISSING_HEADER = <<EOL;
# add the missing texts and run locales.pl to rebuild
EOL
  $LOST_HEADER  = <<EOL;
# The last 50 text strings, that have been removed.
# This file has been auto-generated by locales.pl. Please don't edit!
EOL
}

sub parse_args {
  my ($help, $man);

  GetOptions(
    'no-custom-files' => \$opt_n,
    'check-files'     => \$opt_c,
    'verbose'         => \$opt_v,
    'help'            => \$help,
    'man'             => \$man,
    'debug'           => \$debug,
  );

  if ($help) {
    pod2usage(1);
    exit 0;
  }

  if ($man) {
    pod2usage(-exitstatus => 0, -verbose => 2);
    exit 0;
  }

  if (@ARGV) {
    my $arg = shift @ARGV;
    my $ok  = 0;
    foreach my $dir ("../locale/$arg", "locale/$arg", "../$arg", $arg) {
      next unless -d $dir && -f "$dir/all" && -f "$dir/LANGUAGE";
      $ok = chdir $dir;
      last;
    }

    if (!$ok) {
      print "The locale directory '$arg' could not be found.\n";
      exit 1;
    }

  } elsif (!-f 'all' || !-f 'LANGUAGE') {
    print "locales.pl was not called from a locale/* subdirectory,\n"
      .   "and no locale directory name was given.\n";
    exit 1;
  }
}

sub handle_file {
  my ($file, $dir) = @_;
  print "\n$file" if $opt_v;
  %locale = ();
  %submit = ();

  &scanfile("$dir/$file");

  # scan custom_{module}.pl or {login}_{module}.pl files
  foreach my $customfile (@customfiles) {
    if ($customfile =~ /_$file/) {
      if (-f "$dir/$customfile") {
        &scanfile("$dir/$customfile");
      }
    }
  }

  $file =~ s/\.pl//;
}

sub extract_text_between_parenthesis {
  my ($fh, $line) = @_;
  my ($inside_string, $pos, $text, $quote_next) = (undef, 0, "", 0);

  while (1) {
    if (length($line) <= $pos) {
      $line = <$fh>;
      return ($text, "") unless ($line);
      $pos = 0;
    }

    my $cur_char = substr($line, $pos, 1);

    if (!$inside_string) {
      if ((length($line) >= ($pos + 3)) && (substr($line, $pos, 2)) eq "qq") {
        $inside_string = substr($line, $pos + 2, 1);
        $pos += 2;

      } elsif ((length($line) >= ($pos + 2)) &&
               (substr($line, $pos, 1) eq "q")) {
        $inside_string = substr($line, $pos + 1, 1);
        $pos++;

      } elsif (($cur_char eq '"') || ($cur_char eq '\'')) {
        $inside_string = $cur_char;

      } elsif (($cur_char eq ")") || ($cur_char eq ',')) {
        return ($text, substr($line, $pos + 1));
      }

    } else {
      if ($quote_next) {
        $text .= '\\' unless $cur_char eq "'";
        $text .= $cur_char;
        $quote_next = 0;

      } elsif ($cur_char eq '\\') {
        $quote_next = 1;

      } elsif ($cur_char eq $inside_string) {
        undef($inside_string);

      } else {
        $text .= $cur_char;

      }
    }
    $pos++;
  }
}

sub scanfile {
  my $file = shift;
  my $dont_include_subs = shift;
  my $scanned_files = shift;

  # sanitize file
  $file =~ s=/+=/=g;

  $scanned_files = {} unless ($scanned_files);
  return if ($scanned_files->{$file});
  $scanned_files->{$file} = 1;

  if (!defined $cached{$file}) {

    return unless (-f "$file");

    my $fh = new FileHandle;
    open $fh, "$file" or die "$! : $file";

    my ($is_submit, $line_no, $sub_line_no) = (0, 0, 0);

    while (<$fh>) {
      last if /^\s*__END__/;

      $line_no++;

      # is this another file
      if (/require\s+\W.*\.pl/) {
        my $newfile = $&;
        $newfile =~ s/require\s+\W//;
        $newfile =~ s|bin/mozilla||;
         $cached{$file}{scan}{"$bindir/$newfile"} = 1;
      } elsif (/use\s+SL::([\w:]*)/) {
        my $module =  $1;
        $module    =~ s|::|/|g;
        $cached{$file}{scannosubs}{"../../SL/${module}.pm"} = 1;
      }

      # Some calls to render() are split over multiple lines. Deal
      # with that.
      while (/(?:parse_html_template2?|render)\s*\( *$/) {
        $_ .= <$fh>;
        chomp;
      }

      # is this a template call?
      if (/(?:parse_html_template2?|render)\s*\(\s*[\"\']([\w\/]+)\s*[\"\']/) {
        my $new_file_base = "$basedir/templates/webpages/$1.";
        if (/parse_html_template2/) {
          print "E: " . strip_base($file) . " is still using 'parse_html_template2' for " . strip_base("${new_file_base}html") . ".\n";
        }

        my $found_one = 0;
        foreach my $ext (qw(html js json)) {
          my $new_file = "${new_file_base}${ext}";
          if (-f $new_file) {
            $cached{$file}{scanh}{$new_file} = 1;
            print "." if $opt_v;
            $found_one = 1;
          }
        }

        if ($opt_c && !$found_one) {
          print "W: missing HTML template: " . strip_base($new_file_base) . "{html,json,js} (referenced from " . strip_base($file) . ")\n";
        }
      }

      my $rc = 1;

      while ($rc) {
        if (/Locale/) {
          unless (/^use /) {
            my ($null, $country) = split(/,/);
            $country =~ s/^ +[\"\']//;
            $country =~ s/[\"\'].*//;
          }
        }

        my $postmatch = "";

        # is it a submit button before $locale->
        if (/$submitsearch/) {
          $postmatch = "$'";
          if ($` !~ /locale->text/) {
            $is_submit   = 1;
            $sub_line_no = $line_no;
          }
        }

        my ($found) = / (?: locale->text | \b t8 ) \b .*? \(/x;
        $postmatch = "$'";

        if ($found) {
          my $string;
          ($string, $_) = extract_text_between_parenthesis($fh, $postmatch);
          $postmatch = $_;

          # if there is no $ in the string record it
          unless (($string =~ /\$\D.*/) || ("" eq $string)) {

            # this guarantees one instance of string
            $cached{$file}{locale}{$string} = 1;

            # this one is for all the locales
            $cached{$file}{all}{$string} = 1;

            # is it a submit button before $locale->
            if ($is_submit) {
              $cached{$file}{submit}{$string} = 1;
            }
          }
        } elsif ($postmatch =~ />/) {
          $is_submit = 0;
        }

        # exit loop if there are no more locales on this line
        ($rc) = ($postmatch =~ /locale->text | \b t8/x);

        if (   ($postmatch =~ />/)
            || (!$found && ($sub_line_no != $line_no) && />/)) {
          $is_submit = 0;
        }
      }
    }

    close($fh);

  }

  $alllocales{$_} = 1             for keys %{$cached{$file}{all}};
  $locale{$_}     = 1             for keys %{$cached{$file}{locale}};
  $submit{$_}     = 1             for keys %{$cached{$file}{submit}};

  scanfile($_, 0, $scanned_files) for keys %{$cached{$file}{scan}};
  scanfile($_, 1, $scanned_files) for keys %{$cached{$file}{scannosubs}};
  scanhtmlfile($_)                for keys %{$cached{$file}{scanh}};

  $referenced_html_files{$_} = 1  for keys %{$cached{$file}{scanh}};
}

sub scanmenu {
  my $file = shift;

  my $fh = new FileHandle;
  open $fh, "$file" or die "$! : $file";

  my @a = grep m/^\[/, <$fh>;
  close($fh);

  # strip []
  grep { s/(\[|\])//g } @a;

  foreach my $item (@a) {
    my @b = split /--/, $item;
    foreach my $string (@b) {
      chomp $string;
      $locale{$string}     = 1;
      $alllocales{$string} = 1;
    }
  }

}

sub unescape_template_string {
  my $in =  "$_[0]";
  $in    =~ s/\\(.)/$1/g;
  return $in;
}

sub scanhtmlfile {
  local *IN;

  my $file = shift;

  if (!defined $cached{$file}) {
    my %plugins = ( 'loaded' => { }, 'needed' => { } );

    open(IN, $file) || die $file;

    my $copying  = 0;
    my $issubmit = 0;
    my $text     = "";
    while (my $line = <IN>) {
      chomp($line);

      while ($line =~ m/\[\%[^\w]*use[^\w]+(\w+)[^\w]*?\%\]/gi) {
        $plugins{loaded}->{$1} = 1;
      }

      while ($line =~ m/\[\%[^\w]*(\w+)\.\w+\(/g) {
        my $plugin = $1;
        $plugins{needed}->{$plugin} = 1 if (first { $_ eq $plugin } qw(HTML LxERP JavaScript MultiColumnIterator JSON L P));
      }

      $plugins{needed}->{T8} = 1 if $line =~ m/\[\%.*\|.*\$T8/;

      while ($line =~ m/(?:             # Start von Variante 1: LxERP.t8('...'); ohne darumliegende [% ... %]-Tags
                          (LxERP\.t8)\( #   LxERP.t8(                             ::Parameter $1::
                          ([\'\"])      #   Anfang des zu übersetzenden Strings   ::Parameter $2::
                          (.*?)         #   Der zu übersetzende String            ::Parameter $3::
                          (?<!\\)\2     #   Ende des zu übersetzenden Strings
                        |               # Start von Variante 2: [% '...' | $T8 %]
                          \[\%          #   Template-Start-Tag
                          [\-~#]?       #   Whitespace-Unterdrückung
                          \s*           #   Optional beliebig viele Whitespace
                          ([\'\"])      #   Anfang des zu übersetzenden Strings   ::Parameter $4::
                          (.*?)         #   Der zu übersetzende String            ::Parameter $5::
                          (?<!\\)\4     #   Ende des zu übersetzenden Strings
                          \s*\|\s*      #   Pipe-Zeichen mit optionalen Whitespace davor und danach
                          (\$T8)        #   Filteraufruf                          ::Parameter $6::
                          .*?           #   Optionale Argumente für den Filter
                          \s*           #   Whitespaces
                          [\-~#]?       #   Whitespace-Unterdrückung
                          \%\]          #   Template-Ende-Tag
                        )
                       /ix) {
        my $module = $1 || $6;
        my $string = $3 || $5;
        print "Found filter >>>$string<<<\n" if $debug;
        substr $line, $LAST_MATCH_START[1], $LAST_MATCH_END[0] - $LAST_MATCH_START[0], '';

        $string                         = unescape_template_string($string);
        $cached{$file}{all}{$string}    = 1;
        $cached{$file}{html}{$string}   = 1;
        $cached{$file}{submit}{$string} = 1 if $PREMATCH =~ /$submitsearch/;
        $plugins{needed}->{T8}          = 1 if $module eq '$T8';
        $plugins{needed}->{LxERP}       = 1 if $module eq 'LxERP.t8';
      }

      while ($line =~ m/\[\%          # Template-Start-Tag
                        [\-~#]?       # Whitespace-Unterdrückung
                        \s*           # Optional beliebig viele Whitespace
                        (?:           # Die erkannten Template-Direktiven
                          PROCESS
                        |
                          INCLUDE
                        )
                        \s+           # Mindestens ein Whitespace
                        [\'\"]?       # Anfang des Dateinamens
                        ([^\s]+)      # Beliebig viele Nicht-Whitespaces -- Dateiname
                        \.html        # Endung ".html", ansonsten kann es der Name eines Blocks sein
                       /ix) {
        my $new_file_name = "$basedir/templates/webpages/$1.html";
        $cached{$file}{scanh}{$new_file_name} = 1;
        substr $line, $LAST_MATCH_START[1], $LAST_MATCH_END[0] - $LAST_MATCH_START[0], '';
      }
    }

    close(IN);

    foreach my $plugin (keys %{ $plugins{needed} }) {
      next if ($plugins{loaded}->{$plugin});
      print "E: " . strip_base($file) . " requires the Template plugin '$plugin', but is not loaded with '[\% USE $plugin \%]'.\n";
    }
  }

  # copy back into global arrays
  $alllocales{$_} = 1            for keys %{$cached{$file}{all}};
  $locale{$_}     = 1            for keys %{$cached{$file}{html}};
  $submit{$_}     = 1            for keys %{$cached{$file}{submit}};

  scanhtmlfile($_)               for keys %{$cached{$file}{scanh}};

  $referenced_html_files{$_} = 1 for keys %{$cached{$file}{scanh}};
}

sub scan_javascript_file {
  my ($file) = @_;

  open(my $fh, $file) || die('can not open file: '. $file);

  while( my $line = readline($fh) ) {
    while( $line =~ m/
                    kivi.t8
                    \s*
                    \(
                    \s*
                    ([\'\"])
                    (.*?)
                    (?<!\\)\1
                    /ixg )
    {
      my $text = unescape_template_string($2);

      $jslocale{$text} = 1;
      $alllocales{$text} = 1;
    }
  }

  close($fh);
}
sub search_unused_htmlfiles {
  my @unscanned_dirs = ('../../templates/webpages');

  while (scalar @unscanned_dirs) {
    my $dir = shift @unscanned_dirs;

    foreach my $entry (<$dir/*>) {
      if (-d $entry) {
        push @unscanned_dirs, $entry;

      } elsif (($entry =~ /_master.html$/) && -f $entry && !$referenced_html_files{$entry}) {
        print "W: unused HTML template: " . strip_base($entry) . "\n";

      }
    }
  }
}

sub strip_base {
  my $s =  "$_[0]";             # Create a copy of the string.

  $s    =~ s|^../../||;
  $s    =~ s|templates/webpages/||;

  return $s;
}

sub _single_quote {
  my $val = shift;
  $val =~ s/(\'|\\$)/\\$1/g;
  return  "'" . $val .  "'";
}

sub _double_quote {
  my $val = shift;
  $val =~ s/(\"|\\$)/\\$1/g;
  return  '"'. $val .'"';
}

sub _print_line {
  my $key      = _single_quote(shift);
  my $text     = _single_quote(shift);
  my %params   = @_;
  my $template = $params{template} || qq|  %-29s => %s,\n|;
  my $fh       = $params{fh}       || croak 'need filehandle in _print_line';

  print $fh sprintf $template, $key, $text;
}

sub generate_file {
  my %params = @_;

  my $file      = $params{file}   || croak 'need filename in generate_file';
  my $header    = $params{header};
  my $lines     = $params{data_sub};
  my $data_name = $params{data_name};
  my @delim     = split //, ($params{delim} || '{}');

  open my $fh, '>:encoding(utf8)', $file or die "$! : $file";

  $charset =~ s/\r?\n//g;
  my $emacs_charset = lc $charset;

  print $fh "#!/usr/bin/perl\n# -*- coding: $emacs_charset; -*-\n# vim: fenc=$charset\n\nuse utf8;\n\n";
  print $fh $header, "\n" if $header;
  print $fh "$data_name = $delim[0]\n" if $data_name;

  $lines->(fh => $fh);

  print $fh qq|$delim[1];\n\n1;\n|;
  close $fh;
}

sub slurp {
  my $file = shift;
  do { local ( @ARGV, $/ ) = $file; <> }
}

__END__

=head1 NAME

locales.pl - Collect strings for translation in kivitendo

=head1 SYNOPSIS

locales.pl [options] lang_code

 Options:
  -n, --no-custom-files  Do not process files whose name contains "_"
  -c, --check-files      Run extended checks on HTML files
  -v, --verbose          Be more verbose
  -h, --help             Show this help

=head1 OPTIONS

=over 8

=item B<-n>, B<--no-custom-files>

Do not process files whose name contains "_", e.g. "custom_io.pl".

=item B<-c>, B<--check-files>

Run extended checks on the usage of templates. This can be used to
discover HTML templates that are never used as well as the usage of
non-existing HTML templates.

=item B<-v>, B<--verbose>

Be more verbose.

=back

=head1 DESCRIPTION

This script collects strings from Perl files, the menu.ini file and
HTML templates and puts them into the file "all" for translation.

=cut
