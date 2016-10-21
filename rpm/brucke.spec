%define debug_package %{nil}
%define _service      %{_name}
%define _user         %{_name}
%define _group        %{_name}
%define _conf_dir     %{_sysconfdir}/%{_service}
%define _log_dir      %{_var}/log/%{_service}

Summary: %{_description}
Name: %{_name}
Version: %{_version}
Release: 1%{?dist}
License: Apache License, Version 2.0
URL: https://github.com/klarna/brucke.git
BuildRoot: %{_tmppath}/%{_name}-%{_version}-root
Vendor: Klarna AB
Packager: Ivan Dyachkov <ivan.dyachkov@klarna.com>
Provides: %{_service}
BuildRequires: systemd
%systemd_requires

%description
%{_description}

%prep

%build

%install
mkdir -p %{buildroot}%{_libdir}
mkdir -p %{buildroot}%{_log_dir}
mkdir -p %{buildroot}%{_unitdir}
mkdir -p %{buildroot}%{_conf_dir}
mkdir -p %{buildroot}%{_sysconfdir}/sysconfig
mkdir -p %{buildroot}%{_bindir}
mkdir -p %{buildroot}%{_sharedstatedir}/%{_service}
cp -r _rel/%{_name} %{buildroot}%{_libdir}/

cat > rewrite_sys_config.erl <<EOF
-module(rewrite_sys_config).
main(_) ->
  {ok, [Config0]} = file:consult("rel/sys.config"),
  %% fix lager log root
  LagerConfig0 = proplists:get_value(lager, Config0, []),
  LagerConfig  = lists:keystore(log_root, 1, LagerConfig0, {log_root, "%{_log_dir}"}),
  Config1 = lists:keystore(lager, 1, Config0, {lager, LagerConfig}),

  BruckeConfig0 = proplists:get_value(brucke, Config1, []),
  BruckeConfig  = lists:keystore(config_file, 1, BruckeConfig0, {config_file, "%{_conf_dir}/brucke.config"}),
  Config = lists:keystore(brucke, 1, Config1, {brucke, BruckeConfig}),

  file:write_file("rel/sys.config", io_lib:format("~p.~n", [Config])),
  {ok, _} = file:consult("rel/sys.config"),
  ok.

EOF
escript rewrite_sys_config.erl
rm -f rewrite_sys_config.erl
%{__install} -p -D -m 0644 rel/sys.config %{buildroot}%{_conf_dir}/sys.config
%{__install} -p -D -m 0644 rel/vm.args %{buildroot}%{_conf_dir}/vm.args

cat > %{buildroot}%{_unitdir}/%{_service}.service <<EOF
[Unit]
Description=Apache Kafka Inter-cluster Bridging
After=network.target

[Service]
User=%{_user}
Group=%{_group}
Restart=on-failure
EnvironmentFile=%{_sysconfdir}/sysconfig/%{_service}
ExecStart=%{_libdir}/%{_name}/bin/%{_name} foreground

[Install]
WantedBy=multi-user.target
EOF

cat > %{buildroot}%{_sysconfdir}/sysconfig/%{_service} <<EOF
RUNNER_LOG_DIR=%{_log_dir}
RELX_CONFIG_PATH=%{_sysconfdir}/%{_service}/sys.config
VMARGS_PATH=%{_sysconfdir}/%{_service}/vm.args
PIPE_DIR=%{_sharedstatedir}/%{_service}
EOF

cat > %{buildroot}/%{_bindir}/%{_service} <<EOF
#!/bin/sh
set -a
source %{_sysconfdir}/sysconfig/%{_service}
set +a
if [ \$# -eq 0 ]; then
    %{_libdir}/%{_name}/bin/%{_name} remote_console
else
    %{_libdir}/%{_name}/bin/%{_name} \$@
fi
EOF

%clean
rm -rf $RPM_BUILD_ROOT

%pre
if [ $1 = 1 ]; then
  # Initial installation
  /usr/bin/getent group %{_group} >/dev/null || /usr/sbin/groupadd -r %{_group}
  if ! /usr/bin/getent passwd %{_user} >/dev/null ; then
      /usr/sbin/useradd -r -g %{_group} -m -d %{_sharedstatedir}/%{_service} -c "%{_service}" %{_user}
  fi
fi

%post
%systemd_post %{_service}.service

%preun
%systemd_preun %{_service}.service

%postun
%systemd_postun

%files
%defattr(-,root,root)
%{_libdir}/%{_name}
%attr(0755,root,root) %{_bindir}/%{_service}
%{_unitdir}/%{_service}.service
%config(noreplace) %{_conf_dir}/*
%config(noreplace) %{_sysconfdir}/sysconfig/%{_service}
%attr(0700,%{_user},%{_group}) %dir %{_sharedstatedir}/%{_service}
%attr(0755,%{_user},%{_group}) %dir %{_log_dir}
