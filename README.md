# proxmox-heat-alert
# Proxmox Health Alert

Lightweight Bash script for monitoring a Proxmox host with CPU temperature alerting, VM/CT status reporting, and email notifications.

---

## 🚀 Features

* 🌡️ CPU temperature monitoring (via `sensors`)
* 🖥️ Host resource usage (CPU, RAM, disk)
* 📊 VM and Container (CT) status overview
* 🔍 Detailed metrics for running VMs
* 📦 Disk usage via QEMU Guest Agent (if available)
* 📄 Full health report generation
* 📧 Email alert when temperature threshold is exceeded

---

## 📦 Requirements

* Proxmox VE
* `lm-sensors`
* `mailutils` or `mailx`
* `python3`
* QEMU Guest Agent (optional but recommended)

Install dependencies (Debian/Proxmox):

```bash
apt update
apt install lm-sensors mailutils python3 -y
```

---

## ⚙️ Configuration

Edit the script:

```bash
nano /usr/local/sbin/heat-alert.sh
```

Update:

```bash
MAIL_TO="your@email.com"
TEMP_THRESHOLD=70
```

---

## ▶️ Usage

Run manually:

```bash
bash /usr/local/sbin/heat-alert.sh
```

---

## 🔥 Test alert (force trigger)

```bash
TEMP_THRESHOLD=1 bash /usr/local/sbin/heat-alert.sh
```

---

## ⏰ Cron (recommended)

Run every 5 minutes:

```bash
crontab -e
```

Add:

```bash
*/5 * * * * /usr/local/sbin/heat-alert.sh
```

---

## 📄 Output

* Report file: `/root/proxmox_health_report.txt`
* Includes:

  * Temperature
  * CPU / RAM / Disk
  * Running VMs / CTs
  * Detailed VM metrics

---

## 📧 Email Alerts

An email is sent when:

```
CPU temperature >= TEMP_THRESHOLD
```

Make sure your mail system (Postfix or similar) is configured.

---

## ⚠️ Notes

* Disk usage inside VMs requires **QEMU Guest Agent**
* Without it, fallback uses Proxmox disk allocation
* Sensor output may vary depending on hardware

---



## 👨‍💻 Author

Proxmox sysadmin M Amine ZAAG
