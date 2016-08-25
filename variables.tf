/* Variables */
variable "environment" {
    description = "Name of the environment."
}

variable "aws_region" {
  description = "The AWS region to create things in."
}

variable "aws_ami" {
  description = "The AWS AMI to use."
  default = "ami-fce3c696"
}

variable "availability_zones" {
  description = "List of availability zones."
}

variable "vpc_id" {
  description = "VPC ID"
}

variable "subnet_ids" {
  description = "List of subnets id."
}

variable "app_instance_type" {
    description = "Instance type for the Application."
}

variable "asg_min" {
  description = "Minimun number of instancess in autoscalling group."
}

variable "asg_max" {
  description = "Maximun number of instancess in autoscalling group."
}

variable "asg_desired" {
  description = "Desired number of instancess in autoscalling group."
}
