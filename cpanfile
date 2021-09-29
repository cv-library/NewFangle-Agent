requires 'Devel::Peek';
requires 'Hook::LexWrap';
requires 'Scalar::Util';
requires 'Storable';
requires 'YAML::XS';
requires 'namespace::clean';

recommends 'NewFangle';
recommends 'Plack';

on test => sub {
    requires 'File::Share';
    requires 'Test2::Suite';
};
