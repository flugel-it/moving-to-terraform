# Moving to Terraform

## Introduction

Recently a development company approached us to help them with a Site running on 
AWS WebServices. This site in particular, is on a very popular CMS, using a LAMP
stack together with RDS and ElasticCache, traffic varies quite a lot, specially 
when transmitting live events.

## Challenge and First Steps

Our first challenge was to move Application Servers from an ugly CloudFormation code to
Terraform. The problem here is that as I mentioned before, their platform is already in
production, using RDS and ElasticSearch and inside a dedicated VPC so, in order to have a
succesfull migration without affecting users we needed to integrate Terraform with
what is already in place at AWS.

## Requirements

In order to follow along this example, you need to create some resources in AWS to have a
similar environment to be used by Terraform, representative of what we had at the beggining
of this project.

- An AWS Account
- 1 VPC [ In this example: vpc-1329f474]
- 2 Subnets [ In this example: subnet-e2e6d294 and subnet-e32662c9 ]
- 1 Key Pair [ In this example: abednarik ]

## Terraform

### What is Terraform?

Terraform is a tool for building, maintain, and versioning infrastructure (As code) safely and 
efficiently, it can manage existing and popular service providers as well as custom in-house 
solutions.

### Terraform Configuration

*Note* for the sake of this article, we did a few small modifications Terraform code so anyone
can follow along this guide.

First, head over [moving-to-terraform](https://github.com/flugel-it/moving-to-terraform) Github repository. All the files
involved in this article are there.
If you prefer to read this in *Spanish* there is a [moving-to-terraform](https://github.com/flugel-it/moving-to-terraform/README_es.md) file there as well.

In Terraform, the first thing we need to do is to create same variables. As you might know, variables
store information that we will use everywhere later on, defining a variable is quite simple.
In this case, we defined a *aws_ami* variable, set a description for it and finally a default value.
Note that *default* is set since we plan to use the same AMI in all the environments and clusters,
it's probably one of the few variables we want to have with the exact same value in all environments.

```
variable "aws_ami" {
  description = "The AWS AMI to use."
  default = "ami-fce3c696"
}
```

I choose to store variables in a dedicated file [variables.tf](https://github.com/flugel-it/moving-to-terraform/blob/master/variables.tf). Please, have a look to the file and be familiar with it.

Now, let's get started with [main.tf](https://github.com/flugel-it/moving-to-terraform/blob/master/main.tf).
here's where we set all the resources we plan to use in our cloud environment.
First, we define the provider, Terraform supports multiple providers, like AWS, OpenStack, DigitalOcean,
 Google Cloud, Azure and others.

Here we set the provider and the AWS region defined in *variables.tf* to place our resources there:

```
provider "aws" {
  region = "${var.aws_region}"
}
```

Next we need to set some Security Groups. Terraform has plenty of resources, Security Groups is one of them. 
The way to define a resource is to use the following format: 

```
resource "resource_type" "resource_name" {
[...]
}
```

where *resource_type* is the actual resource we want to configure, in this case *aws_security_group* and *resource_name*
is the name we want to assign to to later reference in our Terraform configuration. Finally
inside the brackets are the resource definitions to configure it.

Here's a complete resource example, a Security Group for our Elastic Load Balancer. As you can see, we use
*${var.environment}* as value in both Name and Tag definitions. This allow us to reuse
the same code for differents environments by just changing a simple variable.
Creating a Security Group is straight forward, we allow HTTP public traffic and all traffic inside
our vpc *${var.vpc_id}*.

```
resource "aws_security_group" "elb-sg" {
  name = "sg_elb_${var.environment}"
  vpc_id = "${var.vpc_id}"

  # HTTP access from anywhere
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "sg-elb-${var.environment}"
  }
}
```

After that, we create the actual ELB. Here there are a few things to look at:

- *security_groups*: When using _${aws_security_group.elb-sg.id}_ terraform can select
the Security Group dynamically and attach that to our ELB.
- *subnets*: Note that we are using brackets here, which means this is a list of values. 
Since we have more than one subnet, we want to make sure that ELB can choose instances in 
any subnet inside our VPC.
- *listener*: Ddefines protocols and ports for both the ELB and for each Instance.
- *health_check*: Sets the way we validate that our instances are working properly, in this
case just with a simple HTTP check.

And finally the last block to setup some values for the ELB, the most important one is
*cross_zone_load_balancing* that distributes incoming traffic evenly between all instances
no matter the zone they are located in.

```
resource "aws_elb" "web-elb" {
  name = "elb-web-${var.environment}"
  security_groups = ["${aws_security_group.elb-sg.id}"]

  subnets = ["${split(",", var.subnet_ids)}"]
  listener {
    instance_port = 80
    instance_protocol = "http"
    lb_port = 80
    lb_protocol = "http"
  }

  health_check {
    healthy_threshold = 2
    unhealthy_threshold = 2
    timeout = 3
    target = "HTTP:80/index.html"
    interval = 30
  }

  cross_zone_load_balancing = true
  idle_timeout = 400
  connection_draining = true
  connection_draining_timeout = 400

  tags {
    Name = "elb-web-${var.environment}"
  }
}

```

Now is time to define the Launch Configuration. This is what runs when a new instance is triggered in 
from an autoscaling action.
A few important things to remark here:
- *name_prefix*: Launch configuration cannot be overwritten or updated every time we want
to change something in it, so we use a name prefix, thus every time something is changed a new launch 
configuration will be created dinamically.
- *user_data*: This is the template where we put our data or script to setup each instance, later on
I will show you a simple shell script to do so.
- *lifecycle*: Since launch configurations cannot be modified, we make sure to create a new configuration
before deleting the previous one.

```

/* Launch Configuration for Autoscalling Group */
resource "aws_launch_configuration" "web-lc" {
  name_prefix = "lc-web-${var.environment}-"
  image_id = "${var.aws_ami}"
  instance_type = "${var.app_instance_type}"
  security_groups = ["${aws_security_group.default.id}"]
  user_data = "${element(template_file.bootstrap.*.rendered, count.index)}"
  key_name = "abednarik"

  lifecycle {
    create_before_destroy = true
  }
}
```

In order to complete our launch process we need to define a template_file to load our custom script.
Here's an example:

```
resource "template_file" "bootstrap" {
    template = "${file("files/bootstrap.sh")}"
    vars {
        cluster_name = "web-${var.environment}"
        roles = "web"
        environment = "${var.environment}"
    }

    lifecycle {
      create_before_destroy = true
    }
}
```

Now is time to create an *autoscaling_group* taking advantage of this great AWS feature,
together with CloudWatch Alerts our stack can grow up and and shrink down accordingly with 
the traffic, keeping costs down.
As you can see here we reference our previous created *launch_configuration*, using our *VPC*
and *subnets*, and setting the desired number of instances along with their maximum and minimum
numbers.


```
resource "aws_autoscaling_group" "web-asg" {
  availability_zones = ["${split(",", var.availability_zones)}"]
  name = "asg-web-${var.environment}"
  max_size = "${var.asg_max}"
  min_size = "${var.asg_min}"
  desired_capacity = "${var.asg_desired}"
  force_delete = true
  launch_configuration = "${aws_launch_configuration.web-lc.name}"
  load_balancers = ["${aws_elb.web-elb.name}"]
  vpc_zone_identifier = ["${split(",", var.subnet_ids)}"]
  tag {
    key = "Name"
    value = "web-${var.environment}"
    propagate_at_launch = "true"
  }
  tag {
    key = "Environment"
    value = "${var.environment}"
    propagate_at_launch = "true"
  }
}
```

Finally we need a Security Group for each instance, simple enough sine it's similar to the 
Security Group created previously for the ELB. Allowing HTTP and SSH access from everywhere.
This is just fine for an example, but I *highly recommend* only allowing SSH from inside
you VPC and using a Bastion Host to access to your Infrastructure.


```
resource "aws_security_group" "default" {
  name = "sg_web_${var.environment}"
  vpc_id = "${var.vpc_id}"

  # SSH access from anywhere
  ingress {
    from_port = 22
    to_port = 22
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # HTTP access from anywhere
  ingress {
    from_port = 80
    to_port = 80
    protocol = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  # outbound internet access
  egress {
    from_port = 0
    to_port = 0
    protocol = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags {
    Name = "sg-ec2-web-${var.environment}"
  }
}
```

### Running Terraform

Now that Terraform configuration is complete, it's time to run it and create all the resources in AWS.

- First, export environment variables with your AWS Credentials, replace *XXX* and *YYY* with the actual keys ;)

```
export AWS_ACCESS_KEY_ID=XXX
export AWS_SECRET_ACCESS_KEY=YYY
```

- Create a .tfvars file with your current data there we set the values for each variable.
I always use the environment name for this file, to reuse the same Terraform configuration for multiple environments.
[This][https://github.com/flugel-it/moving-to-terraform/blob/master/variables.tf] is the one created for this guide.
Just replace this values with your our data.

```
environment = "example"
aws_region="us-east-1"
availability_zones = "us-east-1b,us-east-1c"
vpc_id = "vpc-1329f474"
subnet_ids = "subnet-e2e6d294,subnet-e32662c9"
app_instance_type = "t2.micro"
asg_min = "1"
asg_max = "2"
asg_desired = "1"
```

- Verify Terraform code and show which resources are going to be created

```
terraform  plan -var-file example.tfvars
```

It's always a good idea to use *terraform plan* before actually applying the changes, since we can see all the
modifications beforehand and also to validate the code.

- Run Terraform

```
terraform  apply -var-file example.tfvars
```

This might take a while since we are using a free AWS Instance, so wait a few minutes
until the instance is ready, you can check for that using AWS' Console.
If everything went well, by the end of the output you should get something like we have in [outputs.tf][https://github.com/flugel-it/moving-to-terraform/blob/master/outputs.tf].
Pointing to ELB's FQDN you can verify our stack is working using _curl_ or _wget_ like so:

```
curl -v elb-web-example-213959227.us-east-1.elb.amazonaws.com
```

or

```
wget -O -  -S elb-web-example-213959227.us-east-1.elb.amazonaws.com
```

Excellent! Terraform is working :D

- Now we destroy everything we have created.

```
terraform  destroy -var-file example.tfvars
```

Type *yes* when terraform ask for confirmation.

## Configuration Management and Automation

As I mentioned we used a simple shell script, ideally instead of just installing Nginx, in the user data 
you will have something to install your orchestration software so choice like, SaltStack, Chef, Ansible, 
Puppet, etc. Here's is a small snippet of how we do it with Saltstack.

```
apt-get update
apt-get install -y curl wget python-pip

cd /tmp && wget -O install_salt.sh https://bootstrap.saltstack.com
sh install_salt.sh -i $(echo $HOSTNAME) -P git v2015.8.10
restart salt-minion

salt-call --local grains.setval roles ${roles}
salt-call --local grains.setval environment ${environment}
salt-call state.highstate
```

## Conclusion

Terraform is probably one of the best tools out there to handle resources in the Cloud.
It's straightforward to use and understand, well documented, there are examples everywhere and works like a charm :),
what else can you ask for?.
Now you have no excuse to not to start using it!.
Happy hacking.
