/* ELB Public DNS Record */
output "address" {
  value = "${aws_elb.web-elb.dns_name}"
}
