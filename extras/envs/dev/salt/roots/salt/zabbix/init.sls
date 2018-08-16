zabbix.repository:
  pkg.installed:
    - sources:
      - zabbix-release: http://repo.zabbix.com/zabbix/3.4/ubuntu/pool/main/z/zabbix-release/zabbix-release_3.4-1+xenial_all.deb

zabbix.packages:
  pkg.installed:
    - refresh: True
    - pkgs:
      - zabbix-agent
      - zabbix-frontend-php
      - zabbix-sender
      - zabbix-server-mysql
    - requires:
      - pkg: zabbix.repository

zabbix.grant-sudo-permissions:
  file.append:
    - name: /etc/sudoers
    - text: "zabbix ALL=(ALL) NOPASSWD: /vagrant/zabbix-vha-agent.py"
    - require:
      - pkg: zabbix.packages

zabbix.zabbix-server-service:
  service.running:
    - name: zabbix-server
    - require:
      - file: zabbix.grant-sudo-permissions

zabbix.zabbix-agent-service:
  service.running:
    - name: zabbix-agent
    - require:
      - file: zabbix.grant-sudo-permissions

zabbix.mysql-service:
  service.running:
    - name: mysql
    - require:
      - file: zabbix.grant-sudo-permissions

zabbix.apache2-service:
  service.running:
    - name: apache2
    - require:
      - file: zabbix.grant-sudo-permissions

/etc/apache2/conf-available/zabbix.conf:
  file.replace:
    - pattern: '^\s*#?\s*php_value\s*date\.timezone\s*.*'
    - repl: '    php_value date.timezone Europe/Madrid'
    - watch_in:
      - service: zabbix.apache2-service
    - require:
      - file: zabbix.grant-sudo-permissions

/etc/zabbix/web/zabbix.conf.php:
  file.managed:
    - source: salt://zabbix/zabbix.conf.php.tmpl
    - template: jinja
    - defaults:
      db_name: {{ pillar['mysql.zabbix']['name'] }}
      db_user: {{ pillar['mysql.zabbix']['user'] }}
      db_password: {{ pillar['mysql.zabbix']['password'] }}
    - user: www-data
    - group: www-data
    - mode: 644
    - watch_in:
      - service: zabbix.apache2-service
    - require:
      - file: zabbix.grant-sudo-permissions

{% for name, value in [('DBHost', '127.0.0.1'),
                       ('DBName', pillar['mysql.zabbix']['name']),
                       ('DBUser', pillar['mysql.zabbix']['user']),
                       ('DBPassword', pillar['mysql.zabbix']['password']),] %}
/etc/zabbix/zabbix_server.conf-{{ loop.index }}:
  file.replace:
    - name: /etc/zabbix/zabbix_server.conf
    - pattern: '^\s*#?\s*{{ name }}\s*=\s*.*'
    - repl: {{name}}={{value}}
    - append_if_not_found: True
    - watch_in:
      - service: zabbix.zabbix-server-service
    - require:
      - file: zabbix.grant-sudo-permissions
{% endfor %}

{% for name, value in [('UserParameter', "vha_agent.discovery[*],sudo /vagrant/zabbix-vha-agent.py -i '$1' discover $2"),
                       ('Hostname', 'dev')] %}
/etc/zabbix/zabbix_agentd.conf-{{ loop.index }}:
  file.append:
    - name: /etc/zabbix/zabbix_agentd.conf
    - text: {{name}}={{value}}
    - watch_in:
      - service: zabbix.zabbix-agent-service
    - require:
      - file: zabbix.grant-sudo-permissions
{% endfor %}

zabbix.mysql-disable-auth-socket-plugin:
  cmd.run:
    - runas: root
    - creates: /home/vagrant/.vagrant.zabbix.mysql-disable-auth-socket-plugin
    - name: |
        set -e
        mysql -uroot -e '\
          USE mysql; \
          UPDATE user SET plugin="mysql_native_password" WHERE user="root"; \
          FLUSH PRIVILEGES;'
        touch /home/vagrant/.vagrant.zabbix.mysql-disable-auth-socket-plugin
    - require:
      - service: zabbix.mysql-service

zabbix.mysql-set-root-password:
  cmd.run:
    - runas: vagrant
    - unless: mysqladmin -uroot -p{{ pillar['mysql.root']['password'] }} status
    - name: mysqladmin -uroot password {{ pillar['mysql.root']['password'] }}
    - require:
      - cmd: zabbix.mysql-disable-auth-socket-plugin

zabbix.mysql-create-db:
  mysql_database.present:
    - name: {{ pillar['mysql.zabbix']['name'] }}
    - connection_user: root
    - connection_pass: {{ pillar['mysql.root']['password'] }}
    - connection_charset: utf8
    - collate: utf8_bin
    - require:
      - cmd: zabbix.mysql-set-root-password
  mysql_user.present:
    - name: {{ pillar['mysql.zabbix']['user'] }}
    - host: localhost
    - password: {{ pillar['mysql.zabbix']['password'] }}
    - connection_user: root
    - connection_pass: {{ pillar['mysql.root']['password'] }}
    - connection_charset: utf8
    - require:
      - mysql_database: zabbix.mysql-create-db
  mysql_grants.present:
    - grant: all privileges
    - database: {{ pillar['mysql.zabbix']['name'] }}.*
    - user: {{ pillar['mysql.zabbix']['user'] }}
    - host: localhost
    - connection_user: root
    - connection_pass: {{ pillar['mysql.root']['password'] }}
    - connection_charset: utf8
    - require:
      - mysql_user: zabbix.mysql-create-db
  cmd.run:
    - runas: vagrant
    - creates: /home/vagrant/.vagrant.zabbix.mysql-create-schema
    - name: |
        set -e
        zcat /usr/share/doc/zabbix-server-mysql/create.sql.gz | \
          mysql -u{{ pillar['mysql.zabbix']['user'] }} -p{{ pillar['mysql.zabbix']['password'] }} {{ pillar['mysql.zabbix']['name'] }}
        touch /home/vagrant/.vagrant.zabbix.mysql-create-schema
    - require:
      - mysql_grants: zabbix.mysql-create-db
