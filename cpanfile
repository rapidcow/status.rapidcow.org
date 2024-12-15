# Configuration for Carmel, the CPAN artifact repository manager
# Unlike npm, there are no commands to add dependencies.
# But that shouldn't be an issue; you can just append to
# this file manually -- just 'carmel install' regularly!
#
# Run 'carmel update' to update stuff in the lockfile (snapshot)
# If there is a version you need to pin, use a comma after
# the package name (e.g., require)
#
# You can also just do cpan ... if that simplifies matters....
#
requires 'Git';
requires 'Template';
