package SL::InstallationCheck;

use vars qw(@required_modules);

@required_modules = (
  { "name" => "Class::Accessor", "url" => "http://search.cpan.org/~kasei/" },
  { "name" => "CGI", "url" => "http://search.cpan.org/~lds/" },
  { "name" => "CGI::Ajax", "url" => "http://search.cpan.org/~bct/" },
  { "name" => "DBI", "url" => "http://search.cpan.org/~timb/" },
  { "name" => "DBD::Pg", "url" => "http://search.cpan.org/~dbdpg/" },
  { "name" => "HTML::Template", "url" => "http://search.cpan.org/~samtregar/" },
  { "name" => "Archive::Zip", "url" => "http://search.cpan.org/~adamk/" },
  { "name" => "Text::Iconv", "url" => "http://search.cpan.org/~mpiotr/" },
  { "name" => "Time::HiRes", "url" => "http://search.cpan.org/~jhi/" },
  { "name" => "YAML", "url" => "http://search.cpan.org/~ingy/" },
  { "name" => "IO::Wrap", "url" => "http://search.cpan.org/~dskoll/" },
  { "name" => "Text::CSV_XS", "url" => "http://search.cpan.org/~hmbrand/" },
  { "name" => "List::Util", "url" => "http://search.cpan.org/~gbarr/" },
  );

sub module_available {
  my ($module) = @_;

  if (!defined(eval("require $module;"))) {
    return 0;
  } else {
    return 1;
  }
}

sub test_all_modules {
  return grep { !module_available($_->{name}) } @required_modules;
}

1;
