# Deis in Google Compute Engine

Let's build a Deis cluster in Google's Compute Engine!

## Google

Get a few Google things squared away so we can provison VM instances.

### Google Cloud SDK

Install the Google Cloud SDK from https://developers.google.com/compute/docs/gcutil/#install. You will then need to login with your Google Account:

```console
$ gcloud auth login
Your browser has been opened to visit:

    https://accounts.google.com/o/oauth2/auth?redirect_uri=http%3A%2F%2Flocalhost%3A8085%2F&prompt=select_account&response_type=code&client_id=22535940678.apps.googleusercontent.com&scope=https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fappengine.admin+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fbigquery+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcompute+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fdevstorage.full_control+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fuserinfo.email+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fndev.cloudman+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fcloud-platform+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fsqlservice.admin+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fprediction+https%3A%2F%2Fwww.googleapis.com%2Fauth%2Fprojecthosting&access_type=offline



You are now logged in as [youremail@gmail.com].
Your current project is [named-mason-824].  You can change this setting by running:
  $ gcloud config set project <project>
```

Create a new project in the Google Developer Console (https://console.developers.google.com/project). You should get a project ID like `orbital-gantry-285` back. We'll set it as the default for the SDK tools:

```console
$ gcloud config set project orbital-gantry-285
```

Then navigate to the project and then the settings section in browser. Click to *Enable billing* and fill out the form. This is needed to create resources in Google's Compute Engine. **Please note that you will begin to accrue charges once you create resources such as disks and instances**.

### Cloud Init

Create your cloud init file. It will look something like (be sure to generate and replace your own discovery URL):

```yaml
#cloud-config

coreos:
  etcd:
    # generate a new token for each unique cluster from https://discovery.etcd.io/new
    discovery: https://discovery.etcd.io/<token>
    # multi-region and multi-cloud deployments need to use $public_ipv4
    addr: $private_ipv4:4001
    peer-addr: $private_ipv4:7001
  units:
    - name: etcd.service
      command: start
    - name: fleet.service
      command: start
    - name: format-ephemeral.service
      command: start
      content: |
        [Unit]
        Description=Formats the ephemeral drive
        [Service]
        Type=oneshot
        RemainAfterExit=yes
        ExecStart=/usr/sbin/wipefs -f /dev/disk/by-id/scsi-0Google_PersistentDisk_coredocker
        ExecStart=/usr/sbin/mkfs.btrfs -f /dev/disk/by-id/scsi-0Google_PersistentDisk_coredocker
    - name: var-lib-docker.mount
      command: start
      content: |
        [Unit]
        Description=Mount ephemeral to /var/lib/docker
        Requires=format-ephemeral.service
        Before=docker.service
        [Mount]
        What=/dev/disk/by-id/scsi-0Google_PersistentDisk_coredocker
        Where=/var/lib/docker
        Type=btrfs
```

Save this file as `gce-cloud-init.yaml`. We will use it in the VM instance creation.

### Launch Instances

Create a SSH key that we will use for Deis host communication:

```console
$ ssh-keygen -q -t rsa -f ~/.ssh/deis -N '' -C deis
```

Create some persistent disks to use for `/var/lib/docker`. The default root partition of CoreOS is only around 4 GB and not enough for storing Docker images and instances. The following creates 3 disks sized at 32 GB:

```console
$ gcutil adddisk --zone us-central1-a --size_gb 32 cored1 cored2 cored3

Table of resources:

+--------+---------------+--------+---------+
| name   | zone          | status | size-gb |
+--------+---------------+--------+---------+
| cored1 | us-central1-a | READY  |      32 |
+--------+---------------+--------+---------+
| cored2 | us-central1-a | READY  |      32 |
+--------+---------------+--------+---------+
| cored3 | us-central1-a | READY  |      32 |
+--------+---------------+--------+---------+
```

Launch 3 instances:

```console
$ for num in 1 2 3; do gcutil addinstance --image projects/coreos-cloud/global/images/coreos-alpha-324-2-0-v20140528 --persistent_boot_disk --zone us-central1-a --machine_type n1-standard-2 --tags deis --metadata_from_file user-data:gce-cloud-config.yaml -disk cored${num},deviceName=coredocker --authorized_ssh_keys=core:~/.ssh/deis.pub,core:~/.ssh/google_compute_engine.pub core${num}; done

Table of resources:

+-------+---------------+--------------+---------------+---------+
| name  | network-ip    | external-ip  | zone          | status  |
+-------+---------------+--------------+---------------+---------+
| core1 | 10.240.33.107 | 23.236.59.66 | us-central1-a | RUNNING |
+-------+---------------+--------------+---------------+---------+
| core2 | 10.240.94.33  | 108.59.80.17 | us-central1-a | RUNNING |
+-------+---------------+--------------+---------------+---------+
| core3 | 10.240.28.163 | 108.59.85.85 | us-central1-a | RUNNING |
+-------+---------------+--------------+---------------+---------+
```

### Load Balancing

We will need to load balance the Deis routers so we can get to Deis services (controller and builder) and our applications.

```console
$ gcutil addhttphealthcheck basic-check --request_path /accounts/login/
$ gcutil addtargetpool deis --health_checks basic-check --region us-central1 --instances core1,core2,core3
$ gcutil addforwardingrule deisapp --region us-central1 --target_pool deis

Table of resources:

+---------+-------------+--------------+
| name    | region      | ip           |
+---------+-------------+--------------+
| deisapp | us-central1 | 23.251.153.6 |
+---------+-------------+--------------+
```

Note the forwarding rule external IP address. We will use it to login witht he Deis application. Now allow the ports on the CoreOS nodes:

```console
$ gcutil addfirewall deis-router --target_tags deis --allowed "tcp:80,tcp:2222"
```

## Deis

Time to install Deis!

### Install

Clone the lastest version of Deis:

```console
$ git clone https://github.com/deis/deis.git deis`
```

Then install the CLI:

```console
$ sudo pip install --upgrade ./client/
```

### Setup

The `FLEETCTL_TUNNEL` environment variable provides a gateway to use in the datacenter to one of the CoreOS hosts:

```shell
export FLEETCTL_TUNNEL=23.236.59.66
```
Now we can bootstrap the Deis containers. `DEIS_NUM_INSTANCES` should match the number of EC2 instances launched. `DEIS_NUM_ROUTERS` should be 3 or more Deis application load balancer routers to run:

```shell
DEIS_NUM_INSTANCES=3 DEIS_NUM_ROUTERS=2 make run
```

Then register the admin user (the first user registered is an admin):

```console
$ deis register http://23.251.153.6
```

You are now registered and logged in. Create a new cluster named `deis` to run applications under:

```console
$ deis clusters:create dev dev.mydomain.com --hosts 10.240.33.107,10.240.94.33,10.240.28.163 --auth ~/.ssh/deis
Creating cluster... done, created dev
```

Add your SSH key so you can publish applications:

```console
$ deis keys:add
Found the following SSH public keys:
1) id_rsa.pub andy
Which would you like to use with Deis? 1
Uploading andy to Deis...done
```

### Applications

Creating an application requires that application be housed under git already. Navigate to the application root and then:

```shell
deis create myapp
Creating application... done, created myapp
Git remote deis added
```

Time to push:

```console
$ git push deis master
```

Your application will now be built and run inside the Deis cluster! After the application is pushed it should be running at http://myapp.deis.mydomain.com:

```shell
deis apps:info
```