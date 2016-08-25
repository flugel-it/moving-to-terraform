# Moving to Terraform

## Introduction

Recently a Development Company contact us [flugel.it](http://flugel.it/) in order to
help them to handle a Site running in AWS WebServices. Particularity of this Site, based
in a popular CMS, using a LAMP stack together with RDS and ElasticCache, is that traffic
varies quite a bit, when they have events.

## Challenge and First Steps

Our first challenge was to move Application Servers from an ugly CloudFormation code to
Terraform. The problem here is that as I already mention the Platform is already in
production and using RDS and ElasticSearch, placed inside a dedicated VPC, so in order
to do this migration without affecting users we needed to integrate Terraform with
some resources already created in AWS.

## Requirements

In order to follow alone this example, we need to create some resources in AWS to have a
small but similar environment to what we had when we started working in this project.

- An AWS Account
- 1 VPC [ In this example: vpc-1329f474]
- 2 Subnets [ In this example: subnet-e2e6d294 and subnet-e32662c9 ]
- 1 Key Pair [ In this example: abednarik ]

## Terraform

### What is Terraform?

Terraform is a tool for building, maintain, and versioning infrastructure safely and efficiently. Terraform can manage existing and popular service providers as well as custom in-house solutions.

### Terraform Configuration

*Note* for the sake of this article, we did a few small modifications on the Terraform
code so anyone can follow alone this guide.

First of, head over [moving-to-terraform](https://github.com/abednarik/moving-to-terraform) Github repository. All the files
involved in this article are there.
If you prefer to read this in *Spanish* there is a [moving-to-terraform](https://github.com/abednarik/moving-to-terraform/README_es.md) file there.

In Terraform, the first thing we need to do is to create same variables. As you may know, variables
store information we will use everywhere. Defining a variable is quite simple.
In this case, we define a *aws_ami* variable, we set a description and finally a default value.
Note that *default* is set since we plan to use the same AMI in all environments and clusters,
is probably one of the few variables we want to have exactly the same in all environments.

```
variable "aws_ami" {
  description = "The AWS AMI to use."
  default = "ami-fce3c696"
}
```

I choose to store variables in a dedicated file [variables.tf](https://github.com/abednarik/moving-to-terraform/blob/master/variables.tf). Please, have
a look at the file and get familiar with it.

Now, let get started with the [main.tf](https://github.com/abednarik/moving-to-terraform/blob/master/main.tf).
here is where we set all the resources we plan to use in AWS.
First, we define the provider. Terraform supports multiple providers, Like AWS Web Services, DigitalOcean,
Azure, Google Cloud, OpenStack and others.

Here we set the provider and the AWS region defined in *variables.tf* to place our resources there:

```
provider "aws" {
  region = "${var.aws_region}"
}
```

Next we need to set some security groups. Terraform has plenty of resources. The way to define a resource
is to use the following format: *resource*  *"resource_type"* *"resource_name"* where *resource_type*
is the actual resource we want to configure, in this case *aws_security_group* and *resource_name*
is the name we want to assign to to later reference in our Terraform configuration. Finally
inside the resource definition we set the configuration for that resource.

Here a complete resource, a Security Group for our Elastic Load Balancer. As you can see, we use
a variable *${var.environment}* to include in the Name and also in the Tag. This allow us to reuse
the same code for different environment, just changing a simple variable.
Creating a Security Group is straight forward, we allow HTTP public traffic and everything inside
our vpc *${var.vpc_id}*

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

After that we need to create the actual ELB. Here there are a few things to have a look:

- *security_groups*: As you can see here we use _${aws_security_group.elb-sg.id}_
this mean that terraform will peak the Security Group created above dynamically
and attach that to our ELB.
- *subnets*: Note that we are using brackets, which means this is a list of multiple
values. Since we have more than one subnet, we want to make sure that ELB can peak
instances in any subnet inside our VPC.
- *listener*: This block is where we define protocols and ports for both the ELB and for each
Instance.
- *health_check*: Here we set how we can validate that our instances are working properly
doing a simple HTTP health check

And finally the last block to setup some values for the ELB, the most important one is
*cross_zone_load_balancing* to distribute incoming traffic evenly between all instances
no matters in which zone they are located.

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

Now is time to define the Launch Configuration. This is basically what do you run when a new
instance is triggered in an autoscaling action.
A few important things to remark here:
- *name_prefix*: Since launch configuration cannot be overwritten or updated every time we want
to change something, we use a name prefix, so every time we change something a new launch configuration
will be created.
- *user_data*: This is the template where we handle our data/script to setup each instance. later
I will show you a simple shell script to do so.
- *lifecycle*: Since launch configuration are unique, we want to make sure that a new configuration
is created before deleting the previous one.

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
Here a simple example to do that

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

Now is time to create an *autoscaling_group* to take advantage of this great future of AWS.
This together with a CloudWatch Alert will allow our stack to grow when there is more traffic
and scale down and save some costs when there is no need to have too much resources.
As you can see here we reference our previous created *launch_configuration*, we use our *VPC*
and *subnets* and we set the desired number of instances, together with the limits of maximum and
minimum instances.


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

Finally we need a Security Group for each instance. As you can see this is quite simple
and similar to the Security Group created for the ELB. We allow HTTP and SSH access from
everywhere.
This is just fine  for this example, but I *highly recommend* only allowing ssh from inside
you VPC and using a jump host to get access to your Infrastructure.


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

Now that Terraform configuration is complete, is time to run it and create all the resources in AWS.

- First export your AWS Credentials, replace *XXX* and *YYY* with the actual keys :)

```
export AWS_ACCESS_KEY_ID=XXX
export AWS_SECRET_ACCESS_KEY=YYY
```

- Create a .tfvars file with your current data. Her e we set the values for each variable defined.
I always use the environment name for this file, to reuse the same Terraform configuration for multiple environments.
[This][https://github.com/abednarik/moving-to-terraform/blob/master/variables.tf] is the one created for this guide.
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

- Verify Terraform code and show which resources will be created

```
terraform  plan -var-file example.tfvars
```

Is always a good idea to use *terraform plan* before actually running it, since we can see all the
modification we are about to execute and also to validate the code.

- Run Terraform

```
terraform  apply -var-file example.tfvars
```

This will take a while since we are using a small AWS Instance that is free to use. Wait a few minutes
until the instance is ready. You can check this using AWS Console.
If everything went well, you should get at the end what we have in [outputs.tf][https://github.com/abednarik/moving-to-terraform/blob/master/outputs.tf].
We use this file to show details of created resources, in this case the ELB fqdn, in my case is:
*elb-web-example-213959227.us-east-1.elb.amazonaws.com*
You can verify our stack is working using curl or wget like this:


```
curl -v elb-web-example-213959227.us-east-1.elb.amazonaws.com
```

or

```
wget -O -  -S elb-web-example-213959227.us-east-1.elb.amazonaws.com
```

Excellent! Terraform is working :D

- Finally destroy everything we created

```
terraform  destroy -var-file example.tfvars
```

Type *yes* when terraform ask for confirmation.

## Configuration Management and Automation

As I already mention here we use just a simple shell script. Ideally instead of just installing
Nginx, in thu user data you will have something to install your desired software like SaltStack, Chef
or Puppet, set a role and deploy tour instance. Here is a small snippet on how we do it with Saltstack.

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

Terraform is probably one of the best tools out there to handle resources in Cloud Providers.
Is easy, well documented, there are examples everywhere and works great :)
