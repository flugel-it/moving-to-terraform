/* Specify the provider and access details */
provider "aws" {
  region = "${var.aws_region}"
}

/* Security Group for ELB */
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

/* ELB for Web/Application Servers */
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

/* Template for bootstrap */
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

/* Autoscalling Group */
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


/* Security Group for Ec2 Instances */
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
