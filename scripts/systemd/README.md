
```bash
sudo cp /data/hg_dnmpr/scripts/systemd/docker-mysql-backup.service /etc/systemd/system/
sudo cp /data/hg_dnmpr/scripts/systemd/docker-mysql-backup.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now docker-mysql-backup.timer
sudo systemctl status docker-mysql-backup.timer --no-pager
sudo systemctl list-timers --all | rg docker-mysql-backup
```

��ѡ��֤���ֶ�����һ�α������񣩣�

```bash
sudo systemctl start docker-mysql-backup.service
sudo systemctl status docker-mysql-backup.service --no-pager
sudo journalctl -u docker-mysql-backup.service -n 100 --no-pager
```