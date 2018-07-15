package Report::Csv;

use strict;
use warnings;
use File::FindLib 'lib';

use Parse::CSV;
use SQL::Abstract;
use Parallel::ForkManager;
use DB;
use JSON;
use Core;
use Utils;

sub new {
    my $self = shift;
    my $file = shift;
    die "Unable to open file '$file' use fullpath" unless (-f $file);
    my $csv = Parse::CSV->new(
        file  => $file,
        names => 1,
    );

    my $class = {
        _csv  => $csv,
        _sql  => SQL::Abstract->new(),
        _db   => DB->new->connect_db(),
        _log  => Core->new->dashboard_logger,
        _util => Utils->new,
    };

    return bless($class, $self);
}

sub process_csv_rows {
    my ($self) = @_;
    my $sql    = $self->{_sql};
    my $csv    = $self->{_csv};
    my $log    = $self->{_log};
    my $count  = 0;
    while (my $row = $csv->fetch) {
        ++$count;

        # my $pm = new Parallel::ForkManager(5); # does weired behavior when set on
        # $pm->start and next;  #fork and forgot
        my $data = $self->get_mapped_data($row);
        $data->{'status'} ||= 'UNKNOWN';
        $self->check_and_insert_or_update_tickets($data);
        $self->check_and_insert_or_update_user_tickets($data);

        # $pm->finish;

    }
    $log->info("Proccessed Total: $count Rows");
    return;
}

sub check_and_insert_or_update_tickets {
    my ($self, $data) = @_;
    my $db   = $self->{_db};
    my $sql  = $self->{_sql};
    my $log  = $self->{_log};
    my $util = $self->{_util};
    my $res  = $db->prepare('SELECT 1 FROM tickets WHERE  ticket_id= ?')->execute($data->{ticket_id});
    $res or ($log->logconfess("execution failed: " . $db->errstr()));

    foreach (qw/last_viewed created updated eta resolved/) {
        if (exists $data->{$_}) {    #correct timestamp
            if ($data->{$_} ne '') {
                $data->{$_} = $util->to_db_timestamp($data->{$_});

                # $data->{$_} .=':00';
            } else {
                $data->{$_} = '2000-01-01 00:00:01';
            }
        }
    }

    #update the info for now
    my ($stmt, @bind) =
        $res ne '0E0'
      ? $sql->update('tickets', $data, { ticket_id => $data->{ticket_id} })
      : $sql->insert('tickets', $data);
    my $sth = $db->prepare($stmt);
    $sth->execute(@bind) or ($log->logconfess("execution failed:" . $db->errstr()));
    $log->info("tickets table has been updated successfully");
    return;
}

sub check_and_insert_or_update_user_tickets {
    my ($self, $data) = @_;
    my $db     = $self->{_db};
    my $sql    = $self->{_sql};
    my $log    = $self->{_log};
    my $dev    = '';
    my $update = 0;
    my $sth    = $db->prepare("SELECT user_id FROM users");
    $sth->execute();
    my @dev_list = @{ $db->selectcol_arrayref('select user_id from users') };

    #Took lot of efforts can't be optimized
    #dev is assignee ?
    foreach (@dev_list) {
        $dev = $data->{assignee} if (lc($data->{assignee}) eq lc($_));
    }

    #dev is creator ?

    foreach (@dev_list) {
        $dev = $data->{creator} if (lc($data->{creator}) eq lc($_) and $dev eq '');
    }

    #dev is reporter ?
    foreach (@dev_list) {
        $dev = $data->{reporter} if (lc($data->{reporter}) eq lc($_) and $dev eq '');
    }

    #dev is certainly from this org
    $dev = 'unknown-dev' if ($dev eq '');

    my @type = split('-', $data->{ticket_id});
    my $record = {
        ticket_id => $data->{ticket_id},
        user_id   => $dev,
        type      => $type[0],
    };

    my $res =
      $db->prepare('SELECT 1 FROM user_tickets WHERE  ticket_id= ? and user_id = ?')->execute($data->{ticket_id}, $dev);
    if ($res == 1) {
        $log->debug("SKIPPED Ticket '$data->{ticket_id}' for user '$dev' already exists");
        return;
    }

    my $ticket_query = $db->prepare('SELECT id,user_id,ticket_id FROM user_tickets WHERE ticket_id= ?');
    $ticket_query->execute($data->{ticket_id});
    my $dev_row = $ticket_query->fetchrow_hashref();

    if (defined $dev_row && exists $dev_row->{ticket_id}) {

        #ticket has been transitioned update the dev
        if ($dev_row->{user_id} ne $dev && $dev_row->{ticket_id} eq $data->{ticket_id}) {
            $update = 1;
            delete $record->{ticket_id};    #dont need to update ticket_id
            delete $record->{type};         #dont need to update type
            $log->info("UPDATED Ticket '$data->{ticket_id}' has been TRANSITIONED from '$dev_row->{user_id}' to '$dev' and updated in DB");
        }
    }
    eval {
        my ($stmt, @bind) =
            $update
          ? $sql->update('user_tickets', $record, { id => $dev_row->{id} })
          : $sql->insert('user_tickets', $record);
        my $sth_ut = $db->prepare($stmt);
        $sth_ut->execute(@bind);
        $log->info("Ticket $data->{ticket_id} has been added for user '$dev'") if (!$update);
    };

    if ($@) {
        $log->error("ERROR execution failed DB error:" . $db->errstr() . " \n SYSTEM capture: $@");
        return;
    }

}

sub get_mapped_data {
    my ($self, $raw_data) = @_;
    my $data = {};
    $data->{metadata} = encode_json $raw_data;
    my $csv_fileds_map = {
        'Issue key'                        => 'ticket_id',
        'Custom field (Expected Delivery)' => 'eta',
        'Status'                           => 'status',
        'Priority'                         => 'priority',
        'Summary'                          => 'summary',
        'Project key'                      => 'project',
        'Issue id'                         => 'issue_id',
        'Parent id'                        => 'parent_id',
        'Issue Type'                       => 'issue_type',
        'Resolution'                       => 'resolution',
        'Assignee'                         => 'assignee',
        'Reporter'                         => 'reporter',
        'Creator'                          => 'creator',
        'Updated'                          => 'updated',
        'Last Viewed'                      => 'last_viewed',
        'Resolved'                         => 'resolved',
        'Labels'                           => 'labels',
        'Created'                          => 'created',
    };

    foreach my $k (keys %$raw_data) {
        no warnings;
        next unless (exists $raw_data->{$k});
        $data->{ $csv_fileds_map->{$k} } = $raw_data->{$k};
    }
    delete $data->{''};    #weired key deletion
    return $data;
}

sub get_ticket_type {
    return split('-', $_[1]);
}

1;
