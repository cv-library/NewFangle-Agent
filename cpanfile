requires 'Devel::Peek';
requires 'Hash::Merge';
requires 'NewFangle';
requires 'Scalar::Util';
requires 'Storable';
requires 'Syntax::Keyword::Defer';
requires 'YAML::XS';
requires 'namespace::clean';

recommends 'Plack';

on test => sub {
    requires 'File::Share';
    requires 'Test2::Suite';
    recommends 'Plack::Middleware::ForceEnv';
};
