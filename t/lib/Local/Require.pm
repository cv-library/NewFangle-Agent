package Local::Require;

sub parent { child(@_) }
sub child  { scalar @_ }

1;
