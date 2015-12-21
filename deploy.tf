###############################################################################
#
# A simple K8s cluster in DO
#
###############################################################################


###############################################################################
#
# Get variables from command line or environment
#
###############################################################################


variable "do_token" {}
variable "pub_key" {}
variable "pvt_key" {}
variable "ssh_fingerprint" {}


###############################################################################
#
# Specify provider
#
###############################################################################


provider "digitalocean" {
  token = "${var.do_token}"
}


###############################################################################
#
# Etcd host
#
###############################################################################


resource "digitalocean_droplet" "k8s_etcd" {
    image = "coreos-alpha"
    name = "k8s-etcd"
    region = "nyc3"
    size = "512mb"
    private_networking = true
    user_data = "${file("00-etcd.yaml")}"
    ssh_keys = [
        "${var.ssh_fingerprint}"
    ]
}


###############################################################################
#
# Master host's user data template
#
###############################################################################


resource "template_file" "master_yaml" {
    template = "${file("01-master.yaml")}"
    vars {
        DNS_SERVICE_IP = "11.1.2.10"
        ETCD_IP = "${digitalocean_droplet.k8s_etcd.ipv4_address_private}"
        K8S_SERVICE_IP = "11.1.2.1"
        POD_NETWORK = "10.2.0.0/16"
        SERVICE_IP_RANGE = "11.1.2.0/24"
    }
}


###############################################################################
#
# Master host
#
###############################################################################


resource "digitalocean_droplet" "k8s_master" {
    image = "coreos-alpha"
    name = "k8s-master"
    region = "nyc3"
    size = "512mb"
    private_networking = true
    user_data = "${template_file.master_yaml.rendered}"
    ssh_keys = [
        "${var.ssh_fingerprint}"
    ]

    # Node created, let's generate the TLS assets
    provisioner "local-exec" {
        command = "./secrets/generate-tls-assets.sh ${digitalocean_droplet.k8s_master.ipv4_address_private}" 
    }

    # Provision Master's TLS Assets
    provisioner "file" {
        source = "./secrets/ca.pem"
        destination = "/home/core/ca.pem"
        connection {
            user = "core"
        }
    }

    provisioner "file" {
        source = "./secrets/apiserver.pem"
        destination = "/home/core/apiserver.pem"
        connection {
            user = "core"
        }
    }

    provisioner "file" {
        source = "./secrets/apiserver-key.pem"
        destination = "/home/core/apiserver-key.pem"
        connection {
            user = "core"
        }
    }

    provisioner "remote-exec" {
        inline = [
            "sudo mkdir -p /etc/kubernetes/ssl",
            "sudo mv /home/core/{ca,apiserver,apiserver-key}.pem /etc/kubernetes/ssl/.",
            "sudo chmod 600 /etc/kubernetes/ssl/*-key.pem",
            "sudo chown root:root /etc/kubernetes/ssl/*-key.pem"
        ]
        connection {
            user = "core"
        }
    }

    # Start kubelet and create kube-system namespace
    provisioner "remote-exec" {
        inline = [
            "sudo systemctl start kubelet",
            "sudo systemctl enable kubelet",
            "until $(curl --output /dev/null --silent --head --fail http://127.0.0.1:8080); do printf '.'; sleep 5; done",
            "curl -XPOST -d'{\"apiVersion\":\"v1\",\"kind\":\"Namespace\",\"metadata\":{\"name\":\"kube-system\"}}' http://127.0.0.1:8080/api/v1/namespaces"
        ]
        connection {
            user = "core"
        }
    }
}


###############################################################################
#
# Worker host's user data template
#
###############################################################################


resource "template_file" "worker_yaml" {
    template = "${file("02-worker.yaml")}"
    vars {
        DNS_SERVICE_IP = "11.1.2.10"
        ETCD_IP = "${digitalocean_droplet.k8s_etcd.ipv4_address_private}"
        MASTER_HOST = "${digitalocean_droplet.k8s_master.ipv4_address_private}"
    }
}


###############################################################################
#
# Worker hosts
#
###############################################################################


resource "digitalocean_droplet" "k8s_worker_01" {
    image = "coreos-alpha"
    name = "k8s-worker-01"
    region = "nyc3"
    size = "512mb"
    private_networking = true
    user_data = "${template_file.worker_yaml.rendered}"
    ssh_keys = [
        "${var.ssh_fingerprint}"
    ]

    # Provision Master's TLS Assets
    provisioner "file" {
        source = "./secrets/ca.pem"
        destination = "/home/core/ca.pem"
        connection {
            user = "core"
        }
    }

    provisioner "file" {
        source = "./secrets/apiserver.pem"
        destination = "/home/core/worker.pem"
        connection {
            user = "core"
        }
    }

    provisioner "file" {
        source = "./secrets/apiserver-key.pem"
        destination = "/home/core/worker-key.pem"
        connection {
            user = "core"
        }
    }

    provisioner "remote-exec" {
        inline = [
            "sudo mkdir -p /etc/kubernetes/ssl",
            "sudo mv /home/core/{ca,worker,worker-key}.pem /etc/kubernetes/ssl/.",
            "sudo chmod 600 /etc/kubernetes/ssl/*-key.pem",
            "sudo chown root:root /etc/kubernetes/ssl/*-key.pem"
        ]
        connection {
            user = "core"
        }
    }

    # Start kubelet and create kube-system namespace
    provisioner "remote-exec" {
        inline = [
            "sudo systemctl start kubelet",
            "sudo systemctl enable kubelet"
        ]
        connection {
            user = "core"
        }
    }
}

