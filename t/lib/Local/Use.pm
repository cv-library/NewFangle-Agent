package Local::Use;

sub parent { child(@_) }
sub child  { scalar @_ }

1;
