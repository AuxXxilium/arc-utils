<center><img width="845" alt="arc_loader" src="https://github.com/AuxXxilium/AuxXxilium/assets/67025065/ef975a36-9f3e-4cfb-813c-402db69611e7"></center>

# These are Utilities for usage with Arc Loader

### Arc Benchmark

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://bench.auxxxilium.tech | bash -s /volume1 1G 6
```

Custom Values:
```
curl -fsSL https://bench.auxxxilium.tech | bash -s PATH SIZE GEEKBENCH_VERSION
```

### ABB activation

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://abb.auxxxilium.tech | bash
```

### Forcemount (Create a storage pool on a disk type that DSM does not support (e.g., Hyper-V virtual disks))

This needs to run as 'root' while DSM Installation screen is shown (Usage at own risk):

```
curl -fsSL https://forcemount.auxxxilium.tech | bash
```

### SVE (Install Surveillance Video Extension on every system)

This needs to run as 'root' (Usage at own risk):

```
curl -fsSL https://sve.auxxxilium.tech | bash
```