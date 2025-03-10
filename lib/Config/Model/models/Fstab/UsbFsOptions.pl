#
# This file is part of Config-Model
#
# This software is Copyright (c) 2005-2022 by Dominique Dumont.
#
# This is free software, licensed under:
#
#   The GNU Lesser General Public License, Version 2.1, February 1999
#
use strict;
use warnings;

return [
  {
    'author' => [
      'Dominique Dumont'
    ],
    'class_description' => 'usbfs options',
    'copyright' => [
      '2010,2011 Dominique Dumont'
    ],
    'element' => [
      'devuid',
      {
        'type' => 'leaf',
        'upstream_default' => '0',
        'value_type' => 'integer'
      },
      'devgid',
      {
        'type' => 'leaf',
        'upstream_default' => '0',
        'value_type' => 'integer'
      },
      'busuid',
      {
        'type' => 'leaf',
        'upstream_default' => '0',
        'value_type' => 'integer'
      },
      'budgid',
      {
        'type' => 'leaf',
        'upstream_default' => '0',
        'value_type' => 'integer'
      },
      'listuid',
      {
        'type' => 'leaf',
        'upstream_default' => '0',
        'value_type' => 'integer'
      },
      'listgid',
      {
        'type' => 'leaf',
        'upstream_default' => '0',
        'value_type' => 'integer'
      },
      'devmode',
      {
        'type' => 'leaf',
        'upstream_default' => '0644',
        'value_type' => 'integer'
      },
      'busmode',
      {
        'type' => 'leaf',
        'upstream_default' => '0555',
        'value_type' => 'integer'
      },
      'listmode',
      {
        'type' => 'leaf',
        'upstream_default' => '0444',
        'value_type' => 'integer'
      }
    ],
    'include' => [
      'Fstab::CommonOptions'
    ],
    'license' => 'LGPL2',
    'name' => 'Fstab::UsbFsOptions'
  }
]
;

