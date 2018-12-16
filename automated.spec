Name:      automated
Version:   %{rpm_version}
Release:   %{rpm_release}
Summary:   An automation tool
URL:       https://github.com/node13h/automated
License:   GPLv3+
BuildArch: noarch
Source0:   %{sdist_tarball}

%description
A tool to remotely execute your Bash code

%prep
%setup -n %{sdist_dir}

%clean
rm -rf --one-file-system --preserve-root -- "%{buildroot}"

%install
make install DESTDIR="%{buildroot}" PREFIX="%{prefix}"

%files
%{_bindir}/*
%{_libdir}/*
%{_defaultdocdir}/*
