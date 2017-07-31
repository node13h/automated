Name:      automated
Version:   %{rpm_version}
Release:   %{rpm_release}
Summary:   An automation tool
URL:       https://github.com/node13h/automated
License:   GPLv3+
BuildArch: noarch
Source0:   automated-%{full_version}.tar.gz

%description
A tool to remotely execute your Bash code

%prep
%setup -n automated-%{full_version}

%clean
rm -rf --one-file-system --preserve-root -- "%{buildroot}"

%install
make install DESTDIR="%{buildroot}" prefix="%{prefix}"

%files
%{_bindir}/*
%{_libdir}/*
%{_defaultdocdir}/*
