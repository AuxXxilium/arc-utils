<center><img width="845" alt="arc_loader" src="https://github.com/AuxXxilium/AuxXxilium/assets/67025065/ef975a36-9f3e-4cfb-813c-402db69611e7"></center>

# These are Utilities for usage with Arc Loader

### Root login to DSM

```
sudo -i
```

### Arc Benchmark

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://bench.auxxxilium.tech -o /root/bench.sh
chmod +x /root/bench.sh
/root/bench.sh
```

### ABB activation

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://abb.auxxxilium.tech -o /root/activation
chmod +x /root/activation
/root/activation
```

### Surveillance Video Extension

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://sve.auxxxilium.tech -o /root/installsve
chmod +x /root/installsve
/root/installsve
```

### Forcemount (Create a storage pool on a disk type that DSM does not support (e.g., Hyper-V virtual disks))

This needs to run as 'root' while DSM Installation screen is shown (Usage at own risk):

```
curl -fsSL https://forcemount.auxxxilium.tech -o /root/forcemount
chmod +x /root/forcemount
/root/forcemount