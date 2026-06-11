#!/bin/bash

printf "Patching .terraform/modules/eks/variables.tf \n"
perl -0777 -i -pe '$n=0; s/default = .*/(++$n==7) ? "default = null" : $&/eg' .terraform/modules/eks/variables.tf 
